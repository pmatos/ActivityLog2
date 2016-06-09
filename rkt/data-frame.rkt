#lang racket/base
;; data-frame.rkt -- utilities for manipulating data, vaguely resembling R's
;; data frame
;;
;; This file is part of ActivityLog2, an fitness activity tracker
;; Copyright (C) 2016 Alex Harsanyi (AlexHarsanyi@gmail.com)
;;
;; This program is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by the Free
;; Software Foundation, either version 3 of the License, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
;; FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
;; more details.

(require db
         math/statistics
         plot
         racket/class
         racket/format
         racket/generator
         racket/list
         racket/match
         racket/math
         racket/vector
         "al-profiler.rkt"
         "fmt-util.rkt"
         "spline-interpolation.rkt")

(provide data-series% data-frame% make-data-frame-from-query valid-only bsearch)

(provide df-describe)

(provide df-histogram make-histogram-renderer make-histogram-renderer/dual)

(provide df-best-avg df-best-avg-aux make-best-avg-renderer best-avg-ticks transform-ticks)

(provide df-statistics df-quantile)


;;.............................................................. bsearch ....

;; Normalize the START/END range for `bsearch`.  Ranges start at 0, maximum is
;; UPLIMIT. If start/end are outside this range they are limited to the range,
;; if they are out of order (start > end) they are reverted.  The function
;; returns two values the new start and end of the range.
(define (normalize-range start end uplimit)
  (let ((nstart (min start end))
        (nend (max start end)))
    (values
     (if (< nstart 0) 0 (if (> nstart uplimit) uplimit nstart))
     (if (< nend 0) 0 (if (> nend uplimit) uplimit nend)))))

;; Search a sorted vector, VEC for a value VAL.  The vector is assumed to
;; contain sorted values, as defined by CMP-FN.  KEY, if present, selects the
;; value to compare (usefull if the vector contains structures and we want to
;; search on a structure slot).  START and END define the sub-range of the
;; vector to search.
;;
;; This value will return an index identifying the position where VAL could be
;; inserted to keep the range sorted.  That is:
;;
;; * if VAL is smaller than the first value in the range, START is returned
;;
;; * if VAL is greater than the last value in the range, END is returned
;;
;; * otherwise, an index is returned representing the location of VAL in the
;; vector (or the "best" location, if val is not found).
;;
;; NOTE: this works like the std::lower_bound() function in C++.
(define (bsearch vec val
                 #:cmp (cmp-fn <=)
                 #:key (key-fn #f)
                 #:start (start 0)
                 #:end (end (vector-length vec)))

  (define (do-search start end)
    (if (= start end)
        start
        ;; Other
        (let* ((mid (exact-truncate (/ (+ start end) 2)))
               (mid-item (vector-ref vec mid))
               (mid-val (if key-fn (key-fn mid-item) mid-item)))
          (if (cmp-fn val mid-val)
              (do-search start mid)
              (if (cmp-fn mid-val val)
                  (do-search (+ mid 1) end)
                  mid)))))

  (let-values ([(true-start true-end)
                (normalize-range start end (vector-length vec))])
    (do-search true-start true-end)))


;;.......................................................... data-series% ....

;; A data-series% represends a column of data in a data frame.  It has a name
;; and the data is stored as vector.  #f is considered the "Not Available"
;; value.
;;
;; A data-series% can be sorted, in which case fast lookup of values is
;; possible (see get-index).
(define data-series%
  (class object%
    (init-field
     name                               ; name of the series
     data                               ; a vector of values
     ;; are the values sorted? (get-index) can be uses on series with sorted
     ;; values.
     [sorted? #f]
     ;; comparison function used by (get-index)
     [cmp-fn <=])

    (super-new)

    (define/public (get-name) name)
    (define/public (set-sorted flag)
      (set! sorted? flag)
      (check-consistency))
    (define/public (get-sorted) sorted?)
    (define/public (get-data) data)
    (define/public (get-count) (vector-length data))

    ;; Find the index of VALUE in this data series.  This assumes that the
    ;; series contains values sorted using <= (or strings using string<=?).  A
    ;; valid index will always be returned if value is not #f. The index
    ;; represents the position where VALUE could be inserted in the series to
    ;; keep the series sorted.  For example, if data-series contains #(1 2 3),
    ;; searching for 2 will return 1, searching for 1.5 will return 1 and
    ;; searching for 0.5 will return 0.
    (define/public (get-index value)
      (if sorted?
          (if value (bsearch data value #:cmp cmp-fn) #f)
          (raise "data-series%/get-index: ~a not sorted" name)))

    ;; Return the number of invalid values (NA's) in the data series.  These
    ;; are #f values.
    (define/public (count-invalid-values)
      (for/sum ([x data] #:unless x) 1))

    ;; Return true if there is at least a valid value in the series.
    (define/public (has-valid-values)
      (not (has-invalid-values)))

    ;; Return true if there is an invalid value in the series
    (define/public (has-invalid-values)
      (eq? (for/first ([x data] #:when x) x) #f))

    (define (check-consistency)
      (when sorted?
        (when (has-invalid-values)
          (raise "data-series% ~a is maked sorted, but has invalid values" name))
        ;; NOTE: we might want to remove this test later, as it is slow for
        ;; larger datasets
        (for ([idx (in-range 1 (get-count))])
          (unless (cmp-fn (vector-ref data (- idx 1))
                          (vector-ref data idx))
            (raise "data-series% ~a not really sorted at index ~a" name idx)))))

    (check-consistency)

    ))


;;.......................................................... data-frame% ....

;; Helper function to select only entries with valie values.  Usefull as a
;; parameter for the #:filter parameter of the select and select* methods of
;; data-frame%
(define (valid-only vec) (for/and ([v vec]) v))

;; A data-frame% holds one or more "columns" of data plus additional
;; properties.  Each column is a data-series% object which has a name and
;; data.  The data structure resembles a table except that new columns are
;; cheap to add and selecting a subset of the columns is a fast operation.
;; Arbitrary key-value pairs can also be stored in the data-frame%.  See
;; `make-session-data-frame' for how this structure can be used to hold the
;; data for a session.
(define data-frame%
  (class object%
    (init [series '()]) (super-new)

    (define data-series (make-hash))
    (define properties (make-hash))

    (for ([s (in-list series)]
          ;; don't add series with no values at all
          #:when (send s has-valid-values))
      (let ([name (send s get-name)])
        (hash-set! data-series name s)))

    ;; Return a list of all the series in the data-frame%.  The list is in no
    ;; particular order.
    (define/public (get-series-names)
      (for/list ([p (in-hash-keys data-series)]) p))

    ;; Return a list of all properties in the data-frame%.  The list is in no
    ;; particular order.
    (define/public (get-property-names)
      (for/list ([p (in-hash-keys properties)]) p))

    ;; Return #t if this data-frame% contains all the series in SERIES-NAMES.
    (define/public (contains? . series-names)
      (for/and ([n series-names])
        (and (hash-ref data-series n #f) #t)))

    ;; Return #t if this data-frame% contains any of the series in
    ;; SERIES-NAMES.
    (define/public (contains/any? . series-names)
      (for/or ([n series-names])
        (and (hash-ref data-series n #f) #t)))

    ;; Retutn the data-series% named NAME.  You might want to use the select
    ;; method instead.
    (define/public (get-series name)
      (define series (hash-ref data-series name (lambda () #f)))
      (unless series
        (raise (format "data-frame%/get-series: ~a not found" name)))
      series)

    (define/public (put-property key value)
      (hash-set! properties key value))

    (define/public (get-property key [default-value-fn (lambda () #f)])
      (hash-ref properties key default-value-fn))

    ;; Store the name of the series used as "weight" in statistics
    ;; calculations.  The weight series is meaningfull if the data in the
    ;; data-frame% is time based and has a non-equal sampling interval (Garmin
    ;; Smart Recording).  In that case, we cannot just average samples, we
    ;; need to weight the samples by the interval they were taken at.  Usefull
    ;; weight series are time and distance ones.
    (define/public (set-default-weight-series series-name)
      (put-property 'weight-series series-name))

    ;; Get the default weight series.
    (define/public (get-default-weight-series)
      (get-property 'weight-series))

    (define (select-internal filter-fn start end name)
      (let* ([series (get-series name)]
             [data (send series get-data)]
             [tstart (or start 0)]
             [tend (or end (vector-length data))]
             [nitems (- tend tstart)])
          (if filter-fn
              (for/vector ([d (in-vector data tstart tend)] #:when (filter-fn d))
                d)
              (if (= nitems (vector-length data))
                  data
                  (vector-copy data tstart tend)))))

    ;; Select a subset of values from a data series NAME.  A vector of values
    ;; is returned.  #:start and #:end define the sub-range of the series to
    ;; filter out and #:filter defines a function which decides if a value
    ;; should be considered or not.
    (define/public (select #:filter (filter-fn #f) #:start (start #f) #:end (end #f) name)
      (select-internal filter-fn start end name))

    (define (select*-internal filter-fn start end . names)
      (define cdata (for/list ([n names]) (select n)))
      (define nitems (length names))
      (define tstart (or start 0))
      (define tend (or end (get-row-count)))

      (define (make-value idx)
        (for/vector #:length nitems ([d cdata]) (vector-ref d idx)))

      (if filter-fn
          (for*/vector ([idx (in-range tstart tend)]
                        [val (in-value (make-value idx))]
                        #:when (filter-fn val))
            val)
          (for/vector #:length (- tend tstart)
                      ([idx (in-range tstart tend)])
            (make-value idx))))

    ;; Select a subset of values from several data series as defined by NAMES.
    ;; A vector is returned, each item is a vector of the selected
    ;; row. #:start and #:end define the sub-range of the series to filter out
    ;; and #:filter defines a function which decides if a value should be
    ;; considered or not (the function receives a single vector containing all
    ;; values).
    (define/public (select* #:filter (filter-fn #f) #:start (start #f) #:end (end #f) . names)
      (apply select*-internal filter-fn start end names))

    ;; Return the position of VALUE in SERIES. Search is done using `bsearch`
    (define/public (get-index series value)
      (let ([s (get-series series)])
        (send s get-index value)))

    ;; Return the positions of VALUES in series.  A list of positions is
    ;; returned.  Search is done using `bsearch`
    (define/public (get-index* series . values)
      (let ([s (get-series series)])
        (for/list ([v values]) (send s get-index v))))

    ;; Returns the number of rows in the data frame.  Note that at this time
    ;; we don't enforce all series to have the same unmber of elements (it is
    ;; not clear whether we should).  This method just returns the number of
    ;; elements in the first series the hash returns.
    (define/public (get-row-count)
      (for/first ([v (in-hash-values data-series)])
        (send v get-count)))

    ;; Add SERIES to the data frame.  If another series by the same name
    ;; exists, it is replaced.
    (define/public (add-series series)
      (let ([name (send series get-name)])
        (hash-set! data-series name series)))

    ;; Generate a new data-series by NAME, and add it to the data frame.  The
    ;; frame is generated by VALUE-FN based on values from BASE-SERIES (a list
    ;; of series names).  VALUE-FN can receive either a single value which is
    ;; a vector of all selected values from BASE-SERIES, or two values in
    ;; which case they are the previous value and the current value (packed as
    ;; vectors).
    (define/public (add-derived-series name base-series value-fn)
      (define data (map base-series value-fn))
      (define series (new data-series% [name name] [data data]))
      (add-series series))

    ;; Create a generator that produces values from SERIES-NAMES (a list of
    ;; series names).  The values are packed into a vector.  This is used by
    ;; `map` and `fold` (see below).
    (define (make-generator series-names #:start (start 0) #:end (end (get-row-count)))
      (define series-data
        (for/list ([s series-names])
          (send (get-series s) get-data)))
      (define vwidth (length series-data))
      (generator
       ()
       (for ([index (in-range start end)])
         (yield (for/vector #:length vwidth ([d series-data])
                  (vector-ref d index))))))

    ;; Apply the function FN over values in BASE-SERIES and return the results
    ;; as a vector. FN can receive either an argument or two arguments (the
    ;; previous and current values).
    (define/public (map base-series fn #:start (start 0) #:end (end (get-row-count)))
      (define generator (make-generator base-series #:start start #:end end))
      (define need-prev-val? (eq? (procedure-arity fn) 2))
      (if need-prev-val?
          (let ([prev-val #f])
            (for/vector ([val (in-producer generator (void))])
              (begin0
                  (fn prev-val val)
                (set! prev-val val))))
          (for/vector ([val (in-producer generator (void))])
            (fn val))))

    ;; Fold (accumulate) a function FN over values in BASE-SERIES. FN can
    ;; receive either two arguments or three arguments (the accumulator, the
    ;; previous and current values).  INIT-VAL is the initial value passed to
    ;; FN.
    (define/public (fold base-series init-val fn #:start (start 0) #:end (end (get-row-count)))
      (define generator (make-generator base-series #:start start #:end end))
      (define need-prev-val? (eq? (procedure-arity fn) 3))
      (define accumulator init-val)
      (if need-prev-val?
          (let ([prev-val #f])
            (for ([val (in-producer generator (void))])
              (set! accumulator (fn accumulator prev-val val))
              (set! prev-val val)))
          (for ([val (in-producer generator (void))])
            (set! accumulator (fn accumulator val))))
      accumulator)

    ))


;........................................... make-data-frame-from-query ....

;; Create a data-frame% from the result of running SQL-QUERY.  Each column
;; from the result will be a series in the data frame, sql-null values will be
;; converted to #f.
(define (make-data-frame-from-query db sql-query . params)
  (define result (apply query db sql-query params))
  (define headers
    (for/list ([hdr (rows-result-headers result)])
      (cond ((assq 'name hdr) => cdr)
            (#t "unnamed"))))
  (define rows (rows-result-rows result))
  (define num-rows (length rows))
  (define data-series
    (for/list ((x (in-range (length headers))))
      (make-vector num-rows #f)))
  (for ([row rows]
        [x (in-range num-rows)])
    (for ([series data-series]
          [y (in-range (length data-series))])
      (let ((val (vector-ref row y)))
        (vector-set! series x (if (sql-null? val) #f val)))))

  (define series
    (for/list ([h headers]
               [s data-series])
      (new data-series% [name h] [data s])))

  (new data-frame% [series series]))


;;.......................................................... df-describe ....

;; Print to the standard output port a nice description of DF, a data-frame%.
;; This is usefull in interactive mode.
(define (df-describe df)

  (define (ppval val)
    (let ((v (~r val #:precision 2)))
      (~a v #:min-width 13 #:align 'right)))
  
  (printf "data-frame: ~a series, ~a items~%"
          (length (send df get-series-names))
          (send df get-row-count))
  (printf "properties:~%")
  (let ((prop-names (send df get-property-names))
        (maxw 0))
    (for ([pn prop-names])
      (set! maxw (max (string-length (~a pn)) maxw)))
    (for ([pn prop-names])
      (display "  ")
      (display (~a pn #:min-width maxw))
      (display " ")
      (display (~a (send df get-property pn) #:max-width (max (- 75 maxw) 10)))
      (newline)))
  (printf "series:~%")
  (let ((series-names (sort (send df get-series-names) string<?))
        (maxw 0))
    (for ([sn series-names])
      (set! maxw (max (string-length (~a sn)) maxw)))
    (display "  ")
    (display (~a " " #:min-width maxw))
    (printf "   NAs           min           max          mean        stddev~%")
    (for ([sn series-names])
      (display "  ")
      (display (~a sn #:min-width maxw))
      (let ((inv (send (send df get-series sn) count-invalid-values)))
        (display " ")
        (display (~r inv #:min-width 5)))
      (let ([stats (df-statistics df sn)])
        (display " ")
        (display (ppval (statistics-min stats)))
        (display " ")
        (display (ppval (statistics-max stats)))
        (display " ")
        (display (ppval (statistics-mean stats)))
        (display " ")
        (display (ppval (statistics-stddev stats)))
        (newline)))))


;;........................................................... histograms ....

;; Return a hash table mapping each sample in the data-frame% DF COLUMN to the
;; number of times it appears in the series.  If WEIGHT is not #f, this is
;; used as the weight of the samples (instead of 1). INITIAL-BUCKETS
;; determines the hash table that is updated, BUCKET-WIDTH allows grouping the
;; samples into intervals (can be less than 1).  INCLUDE-ZEROES? if #f will
;; cause values that are equal to 0 to be discarded.
(define (samples->buckets df column
                          #:weight-column (weight #f)
                          #:initial-buckets [initial-buckets (make-hash)]
                          #:bucket-width [bucket-width 1]
                          #:include-zeroes? [include-zeroes? #t])

  ;; NOTE: using `exact-truncate' instead of `exact-round' works more
  ;; correctly for distributing values into buckets for zones.  The bucket
  ;; value is the start of the interval (as opposed to the middle of the
  ;; interval if `exact-round` would be used.
  (define (val->bucket v) (exact-truncate (/ v bucket-width)))

  (define (weighted-binning buckets prev-val val)
    (when prev-val
      (match-define (vector pws pv) prev-val)
      (match-define (vector ws v) val)
      (when (and pws pv ws v)
        (let* ([dx (- ws pws)]
               [dy (/ (+ v pv) 2)]
               [bucket (val->bucket dy)])
          (when (or (not (zero? bucket)) include-zeroes?)
            (let ([pval (hash-ref buckets bucket 0)])
              (hash-set! buckets bucket (+ dx pval)))))))
    buckets)

  (define (unweighted-binning buckets val)
    (match-define (vector v) val)
    (when v
      (let ([bucket (val->bucket v)])
        (when (or (not (zero? bucket)) include-zeroes?)
          (let ([pval (hash-ref buckets bucket 0)])
            (hash-set! buckets bucket (+ 1 pval))))))
    buckets)

  (send df fold
        (if weight (list weight column) (list column))
        initial-buckets
        (if weight weighted-binning unweighted-binning)))

;; Create a histogram from BUCKETS (a hash table mapping sample value to its
;; rank), as produced by `samples->buckets`.  A histogram is a vector where
;; each value is a vector of sample and rank.  Entries will be created for
;; missing sample value (with 0 rank), so the vector contains all possible
;; sample values.  BUCKET-WIDTH is the width of the sample slot (should be the
;; same value as passed to `samples->buckets`.  When AS-PERCENTAGE? is #t, the
;; ranks are converted to a percentage of the total.
(define (buckets->histogram buckets
                            #:bucket-width (bucket-width 1)
                            #:as-percentage? (as-percentage? #f))

  (define total (for/sum ([v (in-hash-values buckets)]) v))
  (define keys (sort (hash-keys buckets) <))

  (if (> (length keys) 0)
      (let ([min (first keys)]
            [max (last keys)])
        (for/vector #:length (+ 1 (- max min))
                    ([bucket (in-range min (add1 max))])
          (vector (* bucket bucket-width)
                  (let ((val (hash-ref buckets bucket 0)))
                    (if (and as-percentage? (> total 0))
                        (* 100 (/ val total))
                        val)))))
      #f))

;; Drop buckets from boths ends of HISTOGRAM which have elements less than
;; PERCENT of the total.  We stop at the first bucket which has more than
;; PERCENT elements.  Note that empty buckets in the middle are still kept.
;; This is used to make the histogram look nicer on a graph.
(define (trim-histogram-outliers histogram [percent 0.001])
  (define total (for/sum ([b histogram]) (vector-ref b 1)))
  (define min (for/first ([b histogram]
                          [index (vector-length histogram)]
                          #:when (> (/ (vector-ref b 1) total) percent))
                index))
  (define max (for/last ([b histogram]
                         [index (vector-length histogram)]
                         #:when (> (/ (vector-ref b 1) total) percent))
                index))
  (if (and min max)
      (for/vector ([index (in-range min (add1 max))])
        (vector-ref histogram index))
      histogram))

;; Create a histogram of the data-frame% DF COLUMN.  A histogram is a vector
;; of values, each value is a (Vectorof SAMPLE-SLOT RANK).
;;
;; #:weight-column specifies the column to be used for weighting the samples
;; (by default it it uses the weight property stored in the data-frame).  Use
;; #f for no weighting (each sample will have a weight of 1 in that case).
;;
;; #:bucket-width specifies the width of each histogram slot.  Samples are
;; grouped into slots (can be less than 0.1)
;;
;; #:trim-outliers specifies to remove slots from both ends of the histogram
;; that contain less than the specified percentage of values.
;;
;; #:include-zeroes? specifies whether samples with a slot of 0 are included
;; in the histogram or not.
;;
;; #:as-percentage? determines if the data in the histogram represents a
;; percentage (adding up to 100) or it is the rank of each slot.
;;
(define (df-histogram df column
                      #:weight-column [weight (send df get-default-weight-series)]
                      #:bucket-width [bwidth 1]
                      #:trim-outliers [trim #f]
                      #:include-zeroes? [zeroes? #t]
                      #:as-percentage? [as-pct? #f])
  (if (and (send df contains? column)
           (or (not weight) (send df contains? weight)))
      (let ()
        (define buckets
          (samples->buckets df column
                       #:weight-column weight
                       #:bucket-width bwidth
                       #:include-zeroes? zeroes?))
        (define histogram (buckets->histogram buckets
                                              #:bucket-width bwidth
                                              #:as-percentage? as-pct?))
        (if (and trim histogram)
            (trim-histogram-outliers histogram trim)
            histogram))
      #f))

;; Create a historgam plot renderer from DATA (a sequence of [BUCKET
;; NUM-SAMPLES]), as received from `df-histogram` (which see). COLOR will be
;; the color of the plot.  #:skip and #:x-min are used to plot dual
;; histograms, #:label prints the label of the plot.  All these args are sent
;; directly to the `discrete-histogram' call.
;;
;; The resulting plot renderer can be passed to `plot` or any related
;; functions to be displayed.
(define (make-histogram-renderer data
                                 #:color [color #f]
                                 #:skip [skip (discrete-histogram-skip)]
                                 #:x-min [x-min 0]
                                 #:label [label #f])
  (let ((kwd '())
        (val '()))
    (define (add-arg k v) (set! kwd (cons k kwd)) (set! val (cons v val)))
    (let ((max-val #f))
      ;; Determine the max value in the plot
      (for ((d (in-vector data)))
        (let ((v (vector-ref d 1)))
          (when (or (not max-val) (> v max-val))
            (set! max-val v))))
      ;; Make the max value of the plot larger, so the top value does not
      ;; reach the top of the plot area.
      (add-arg '#:y-max (* max-val 1.1)))
    (add-arg '#:x-min x-min)
    (add-arg '#:skip skip)
    (add-arg '#:line-width 2)
    (when color
      (add-arg '#:line-color color))
    (add-arg '#:label label)
    (when color
      (add-arg '#:color color)
      (add-arg '#:alpha 0.8))
    (keyword-apply discrete-histogram kwd val data '())))

;; Return a list of the buckets in a histogram (as made by `df-histogram`).
(define (get-histogram-buckets h)
  (for/list ([e (in-vector h)])
    (vector-ref e 0)))

;; Merge two sorted lists.
(define (merge-lists l1 l2)
  (let loop ((l1 l1)
             (l2 l2)
             (result '()))
    (cond ((null? l1) (append (reverse result) l2))
          ((null? l2) (append (reverse result) l1))
          ((= (car l1) (car l2)) (loop (cdr l1) (cdr l2) (cons (car l1) result)))
          ((< (car l1) (car l2)) (loop (cdr l1) l2 (cons (car l1) result)))
          (#t (loop l1 (cdr l2) (cons (car l2) result))))))

;; Ensure that HISTOGRAM has all buckets in BUCKETS (a sorted list).  This is
;; done by adding buckets with 0 elements if needed.  This is used when
;; histograms for two data series need to be displayed on a single plot.
(define (normalize-histogram histogram buckets)
  (for/vector ([b buckets])
    (or (for/first ([h histogram]
                    #:when (eqv? b (vector-ref h 0)))
          h)
        (vector b 0))))

;; Create a plot renderer with two histograms.
(define (make-histogram-renderer/dual data1 label1
                                      data2 label2
                                      #:color1 [color1 #f]
                                      #:color2 [color2 #f])
  (let ((nbuckets (merge-lists (get-histogram-buckets data1) (get-histogram-buckets data2))))
    (set! data1 (normalize-histogram data1 nbuckets))
    (set! data2 (normalize-histogram data2 nbuckets))
    (let ((h1 (make-histogram-renderer
               data1 #:color color1 #:skip 2.5 #:x-min 0 #:label label1))
          (h2 (make-histogram-renderer
               data2 #:color color2 #:skip 2.5 #:x-min 1 #:label label2)))
      (list h1 h2))))


;;........................................................... statistics ....

(define (weighted-statistics stats prev-val val)
  (if prev-val
      (let ((pws (vector-ref prev-val 0))
            (pv (vector-ref prev-val 1))
            (ws (vector-ref val 0))
            (v (vector-ref val 1)))
        (if (and pws pv ws v)
            (let ([dx (- ws pws)]
                  [dy (/ (+ pv v) 2)])
              (update-statistics stats dy dx))
            stats))
      stats))

(define (unweighted-statistics stats val)
  (define v (vector-ref val 0))
  (if v
      (update-statistics stats v)
      stats))

;; Compute statistics for a series in a data frame.  The statistics will use
;; weighting if a weight series is defined for the data frame.
(define (df-statistics df column
                       #:weight-column [weight (send df get-default-weight-series)]
                       #:start (start 0)
                       #:end (end (send df get-row-count)))
  (if (and (send df contains? column)
           (or (not weight) (send df contains? weight)))
      (if weight
          (send df fold (list weight column)
                empty-statistics weighted-statistics
                #:start start #:end end)
          (send df fold (list column)
                empty-statistics unweighted-statistics
                #:start start #:end end))
      #f))

;; Return the quantiles for the series COLUMN in the dataframe DF.  A list of
;; quantiles is returned as specified by QVALUES, or if no quantiles are
;; specified, the list (0 0.25 0.5 1) is used. #:weight-column has the usual
;; meaning, #:less-than is the ordering function passed to the `quantile`
;; function.
(define (df-quantile df column
                     #:weight-column [weight (send df get-default-weight-series)]
                     #:less-than (lt <)
                     . qvalues)
  (if (and (send df contains? column)
           (or (not weight) (send df contains? weight)))
      (let ((xs-base (send df select column))
            (ws-base (if weight
                         (send df map
                               (list weight)
                               (lambda (prev current)
                                 (if prev
                                     (- (vector-ref current 0) (vector-ref prev 0))
                                     (vector-ref current 0))))
                         #f))
            (quantiles (if (null? qvalues) (list 0 0.25 0.5 0.75 1) qvalues)))
        (if (vector-memq #f xs-base)    ; do we have NA values? remove them.
            (let ((xs (for/vector ([x xs-base] #:when x) x))
                  (ws (if ws-base
                          (for/vector ([(w idx) (in-indexed ws-base)]
                                       #:when (vector-ref xs-base idx))
                            w)
                          #f)))
              (for/list ([q quantiles])
                (quantile q lt xs ws)))
            (for/list ([q quantiles])
              (quantile q lt xs-base ws-base))))
      #f))


;;............................................................. best avg ....

(define (generate-best-avg-durations start limit [growth-factor 1.05])
  (let loop ((series (list start)) (current start))
    (let ((nval (exact-round (* current growth-factor))))
      (when (< nval (+ current 5))
        (set! nval (+ 20 current)))     ; ensure min growth
      (if (< nval limit)
          (loop (cons nval series) nval)
          (reverse series)))))

(define default-best-avg-durations
  (generate-best-avg-durations 10 (* 300 60) 1.2))

(define important-best-avg-durations
  (list 1 5 10 30 60 90 (* 3 60) (* 5 60) (* 10 60) (* 15 60)
        (* 20 60) (* 30 60) (* 45 60) (* 60 60)
        (* 90 60) (* 120 60) (* 180 60)))

;; (printf "(length default-best-avg-durations): ~a~%"
;;         (length default-best-avg-durations))
;; (printf "(length important-best-avg-durations): ~a~%"
;;         (length important-best-avg-durations))

;; Plot ticks for the best-avg plot.  Produces ticks at
;; important-best-avg-durations locations (among other places).
(define (best-avg-ticks)

  (define (->ticks duration-list)
    (for/list ([d duration-list]) (pre-tick d #t)))

  ;; Truncate VAL so it is a multiple of NEAREST.
  (define (trunc val nearest)
    (* nearest (quotient (exact-truncate val) nearest)))

  ;; Generate numbers between START and END, at least MARK-COUNT of them.
  ;; Marks will be generated at a rate that is a multiple of BASE-SKIP.  The
  ;; start position is "rounded" down to a multiple of NEAREST-START.
  (define (generate-marks start end mark-count base-skip nearest-start)
    (let ((interval (max 1 (trunc (/ (- end start) mark-count) base-skip)))
          (actual-start (trunc start nearest-start)))
      (for/list ([d (in-range actual-start end interval)]) d)))

  (define (merge c1 c2)
    (sort (remove-duplicates (append c1 c2)) <))

  (define (generate-ticks start end)
    (define candidates
      (for/list ([d important-best-avg-durations]
                 #:when (and (>= d start) (<= d end)))
        d))
    (if (>= (length candidates) 5)
        (->ticks candidates)
        (let ((marks (generate-marks start end 10 5 30)))
          (->ticks (merge candidates marks)))))

  (define (format-ticks start end ticks)
     (for/list [(tick ticks)]
       (duration->string (pre-tick-value tick))))

  (ticks generate-ticks format-ticks))

;; Given a data series (Vectorof (Vector X Y)), compute the delta series by
;; combining adjacent samples.  The result is a (Listof (Vector Delta-X
;; Slice-Y Pos-X)), where Delta-X is the difference between two adjacent X
;; values and Slice-Y is the "area" (integral) of the slice between the two X
;; values and Pos-X is the X position in the DATA-SERIES for this slice.
(define (make-delta-series data-series)
  (for/list ([first (in-vector data-series)]
             [second (in-vector data-series 1)])
    (match-define (vector x1 y1) first)
    (match-define (vector x2 y2) second)
    (let ((dt (- x2 x1)))
      (vector dt (* dt (/ (+ y1 y2) 2)) x1))))

;; Compute the best averave value from a delta series (as produced by
;; MAKE-DELTA-SERIES) over DURATION.  If INVERTED? is #t, the "best" is
;; condidered the smallest value (this is usefull for pace, vertical
;; oscilation, etc.)
(define (get-best-avg delta-series duration inverted?)

  (define cmp-fn (if inverted? < >))

  (define best-total #f)
  (define best-avg-pos #f)

  (define (maybe-update total start-pos)
    (when (or (not best-total) (and total (cmp-fn total best-total)))
      (set! best-total total)
      (set! best-avg-pos start-pos)))

  (let loop ((running-duration 0)
             (running-total 0)
             (head delta-series)
             (tail delta-series))
    (unless (null? tail)
      (match-define (vector dt y _) (car tail))
      (let ((diff (- (+ running-duration dt) duration)))
        (if (< diff 0)
            ;; running-duration is too small, add more samples
            (loop (+ running-duration dt) (+ running-total y) head (cdr tail))
            ;; ELSE: current sample completes the necessary duration, compute
            ;; the partial slice (for running, dt can be up to 7 seconds!)
            ;; and update the average.
            (let* ((partial-dt (- dt diff))
                   (partial-y (* y (/ partial-dt dt))))
              (match-define (vector dt y s) (car head)) ; NOTE: different dt, y
              (maybe-update (+ running-total partial-y) s)
              ;; Remove oldest element from running-duration, running-total
              ;; and continue.
              (loop (- running-duration dt) (- running-total y) (cdr head) tail))))))

  (vector duration (if best-total (/ best-total duration) #f) best-avg-pos))

;; Construct a data series over the best average values of DATA over
;; DURATIONS.  INVERTED? is passed to get-best-avg.
(define (make-best-avg data [inverted? #f] [durations default-best-avg-durations])
  (if (< (vector-length data) 2)
      '()
      (let ((delta-series (make-delta-series data)))
        (for/list ([d durations])
          (get-best-avg delta-series d inverted?)))))

;; Compute an average in DELTA-SERIES starting at POSITION over the specified
;; DURATION.
(define (compute-avg-at-position delta-series duration position)
  (let ((xtotal 0)
        (ytotal 0))
    (for ([item delta-series] #:break (>= xtotal duration))
      (match-define (vector dx dy pos) item)
      (when (>= pos position)
        (let ((remaining (- duration xtotal)))
          (if (> remaining dx)
              (begin
                (set! xtotal (+ dx xtotal))
                (set! ytotal (+ dy ytotal)))
              (begin
                (let ((slice (/ remaining dx)))
                  (set! xtotal (+ remaining xtotal))
                  (set! ytotal (+ (* slice dy) ytotal))))))))
    (if (> xtotal 0)
        (/ ytotal xtotal)
        #f)))

;; Compute auxiliary averages on DATA-SERIES based on a BEST-AVG graph.  For
;; each value in BEST-AVG we compute the corresponding average in DATA-SERIES
;; (at the same position and duration).
;;
;; For example, for a power best-avg, we can compute the average cadence for
;; the segment on which the best power-duration item was computed.
(define (make-best-avg-aux data-series best-avg)
  (let ((delta-series (make-delta-series data-series)))
    (for/list ([best best-avg])
      (match-define (vector d _ p) best)
      (if p
          (vector d (compute-avg-at-position delta-series d p) p)
          (vector d #f #f)))))

(define (df-best-avg df column
                     #:inverted? (inverted? #f)
                     #:weight-column [weight "elapsed"]
                     #:durations [durations default-best-avg-durations])
  (define (filter-fn val) (and (vector-ref val 0) (vector-ref val 1)))
  (define data (send df select* weight column #:filter filter-fn))
  (make-best-avg data inverted? durations))

(define (df-best-avg-aux df column best-avg-data
                         #:weight-column [weight "elapsed"])
  (define (filter-fn val) (and (vector-ref val 0) (vector-ref val 1)))
  (define data (send df select* weight column #:filter filter-fn))
  (make-best-avg-aux data best-avg-data))

;; Transform TIKS (a ticks struct) so that it really prints values transormed
;; by tr-fun.  This is part of the hack to add a secondary axis to a plot.  It
;; is used to print secondary axis values at the primary axis ticks.
(define (transform-ticks tiks tr-fun)
  (let ([layout (ticks-layout tiks)]
        [format (ticks-format tiks)])
    (ticks
     layout
     (lambda (start end tics)
       (format (tr-fun start)
               (tr-fun end)
               (for/list ([t tics])
                 (pre-tick (tr-fun (pre-tick-value t))
                           (pre-tick-major? t))))))))

;; Return a function that will plot the BEST-AVG data using spline
;; interpolation
(define (best-avg->plot-fn best-avg)
  (let ((data (for/list ([e best-avg] #:when (vector-ref e 1))
                (match-define (vector d m s) e)
                (vector d m))))
    ;; need at least 3 points for spline interpolation
    (if (> (length data) 3)
        (mk-spline-fn data)
        #f)))

(define (transform v smin smax tmin tmax)
  (let ((p (/ (- v smin) (- smax smin))))
    (+ tmin (* p (- tmax tmin)))))

(define (inv-transform v smin smax tmin tmax)
  (let ((p (/ (- v tmin) (- tmax tmin))))
    (+ smin (* p (- smax smin)))))

;; Return the set of transformation parameters so that BEST-AVG-AUX values map
;; onto BEST-AVG plot (for example a 0-100 cadence range can be mapped to a
;; 0-500 watt power graph.  The returned values can be passed to `transform'
;; and `inv-transform'.
(define (get-transform-params best-avg-aux best-avg [zero-base? #t])
  (define tmin (if zero-base? 0 #f))
  (define tmax #f)
  (for ([b best-avg])
    (match-define (vector _1 value _2) b)
    (when value
      (set! tmin (if tmin (min tmin value) value))
      (set! tmax (if tmax (max tmax value) value))))
  (define smin (if zero-base? 0 #f))
  (define smax #f)
  (for ([b best-avg-aux])
    (match-define (vector _1 value _2) b)
    (when value
      (set! smin (if smin (min smin value) value))
      (set! smax (if smax (max smax value) value))))
  (values smin smax tmin tmax))

(define (mk-inverse best-avg-aux best-avg zero-base?)
  (let-values ([(smin smax tmin tmax)
                (get-transform-params best-avg-aux best-avg zero-base?)])
    (lambda (v)
      (inv-transform v smin smax tmin tmax))))

(provide mk-inverse)

;; Normalize (transform) the values in BEST-AVG-AUX so that they can be
;; displayed on the BEST-AVG plot.
(define (normalize-aux best-avg-aux best-avg [zero-base? #t])
  (define tmin (if zero-base? 0 #f))
  (define tmax #f)
  (for ([b best-avg])
    (match-define (vector _1 value _2) b)
    (when value
      (set! tmin (if tmin (min tmin value) value))
      (set! tmax (if tmax (max tmax value) value))))
  (define smin (if zero-base? 0 #f))
  (define smax #f)
  (for ([b best-avg-aux])
    (match-define (vector _1 value _2) b)
    (when value
      (set! smin (if smin (min smin value) value))
      (set! smax (if smax (max smax value) value))))
  (define (tr v) (transform v smin smax tmin tmax))
  (for/list ([data best-avg-aux])
    (match-define (vector duration value position) data)
    (if value
        (vector duration (tr value) position)
        data)))

(define (make-best-avg-renderer best-avg-data (aux-data #f)
                                #:color1 (best-avg-color #f)
                                #:color2 (aux-color #f)
                                #:zero-base? (zero-base? #f))
  (define data-fn (if best-avg-data (best-avg->plot-fn best-avg-data) #f))

  (if (not data-fn)
      #f
      (let ((foo 0))
        (define min-x #f)
        (define max-x #f)
        (for ([b best-avg-data] #:when (vector-ref b 1))
          (unless min-x (set! min-x (vector-ref b 0)))
          (set! max-x (vector-ref b 0)))

        (define aux-fn
          (if aux-data
              (best-avg->plot-fn (normalize-aux aux-data best-avg-data zero-base?))
              #f))

        (define data-rt
          (let ((kwd '()) (val '()))
            (define (add-arg k v) (set! kwd (cons k kwd)) (set! val (cons v val)))
            (when zero-base? (add-arg '#:y-min 0))
            (add-arg '#:width 3)
            (when best-avg-color (add-arg '#:color best-avg-color))
            (keyword-apply function kwd val data-fn min-x max-x '())))
        (define aux-rt
          (if (not aux-fn)
              #f
              (let ((kwd '()) (val '()))
                (define (add-arg k v) (set! kwd (cons k kwd)) (set! val (cons v val)))
                (when zero-base? (add-arg '#:y-min 0))
                (add-arg '#:width 3)
                (add-arg '#:style 'long-dash)
                (when aux-color (add-arg '#:color aux-color))
                (keyword-apply function kwd val aux-fn min-x max-x '()))))

        (if aux-rt (list data-rt aux-rt) data-rt))))


;;................................................................ other ....

(provide time-delay-series
         group-samples
         group-samples/factor
         make-scatter-renderer
         make-scatter-group-renderer)

(define (time-delay-series data-series amount)

  (define (key-fn item) (vector-ref item 2))
  (define (delayed-value start-index)
    (define lookup-val
      (+ (key-fn (vector-ref data-series start-index))
         amount))
    (define index
      (bsearch data-series lookup-val
               #:start start-index
               #:end (+ start-index (exact-truncate amount) (sgn amount))
               #:key key-fn))
    (if (< index (vector-length data-series))
        (vector-ref (vector-ref data-series index) 1)
        #f))

  (for*/vector ([index (in-range (vector-length data-series))]
                [val (in-value (delayed-value index))]
                #:when val)
    (define item (vector-ref data-series index))
    (vector (vector-ref item 0) val (vector-ref item 2))))

(define (group-samples data-series (frac-digits1 0) (frac-digits2 0))

  (define result (make-hash))

  (define mult1 (expt 10 frac-digits1))
  (define inv1 (expt 10 (- frac-digits1)))
  (define mult2 (expt 10 frac-digits2))
  (define inv2 (expt 10 (- frac-digits2)))

  (for ([d data-series])
    (define s1 (vector-ref d 0))
    (define s2 (vector-ref d 1))
    (define cell (cons
                  (exact-round (* s1 mult1))
                  (exact-round (* s2 mult2))))
    (hash-set! result
               cell
               (+ 1 (hash-ref result cell 0))))

  (define result-1 (make-hash))

  (for ([k (in-hash-keys result)])
    (match-define (cons s1 s2) k)
    (define rank (hash-ref result k))
    (hash-set! result-1
               rank
               (cons (vector (* s1 inv1) (* s2 inv2))
                     (hash-ref result-1 rank '()))))
  result-1)

(define (group-samples/factor data-series factor-fn #:key (key #f))
  (define result (make-hash))
  (for ([item data-series])
    (let ((factor (factor-fn (if key (key item) item))))
      (hash-set! result factor (cons item (hash-ref result factor '())))))
  result)

(define (make-scatter-renderer data-series color size label)
  (let ((kwd '()) (val '()))
    (define (add-arg k v) (set! kwd (cons k kwd)) (set! val (cons v val)))
    (add-arg '#:sym 'fullcircle)
    (add-arg '#:size (* (point-size) size))
    ;; (add-arg '#:line-width 2)
    (when label
      (add-arg '#:label label))
    (when color
      (add-arg '#:fill-color color)
      (add-arg '#:color color)
      (add-arg '#:alpha 0.8))
    (keyword-apply points kwd val data-series '())))

(define (make-scatter-group-renderer group color [label #f])
  (for/list ([key (in-hash-keys group)])
    (define data (hash-ref group key))
    (make-scatter-renderer data color (+ 1 (log key)) label)))