
####################################################################
# Finds the median of an ordinal aka ordered factor.
####################################################################
median.ordered <- function(ord) {
    levs <- levels(ord)
    m <- median(as.integer(ord))
    if(floor(m) != m) {
        warning("median is between two values; using the first one")
        m <- floor(m)
    }
    ordered(m, labels = levs, levels = seq_along(levs))
}

################################################################################
# Checks all columns/features in a data frame to ensure
# they are 'finite' meaning not NA, NULL, NaN, etc.
################################################################################
is.finite.data.frame <- function(df){
    sapply(df, function(col) all(is.finite(col)))
}

################################################################################
# Returns a default value if the input is NA.
################################################################################
default <- function(value, default) {
    value[is.na(value)] <- default
    return(value)
}

################################################################################
# the poorly named 'CJ' function is data.table's fast expand.matrix function
################################################################################
cross.join <- function (..., start, end) CJ(...)


################################################################################
# A pass-through to another function that returns a default value if the result
# of the function is not finite.
################################################################################
finite <- function(default=0, f, ...) {
    result <- f(...)
    if(is.finite(result))
        result
    else
        default
}

mean.finite <- function(..., default=0) { 
    finite(default, mean, na.rm=T, ...)
}

sd.finite <- function(..., default=0) {
    finite(default, sd, na.rm=T, ...)
}

min.finite <- function(..., default=0) {
    finite(default, min, na.rm=T, ...)
}

max.finite <- function(..., default=0) { 
    finite(default, max, na.rm=T, ...)
}

################################################################################
# A pass-through to median except that this will always return a finite value.
################################################################################
median.finite <- function(..., default=0) {
    m <- mean(..., na.rm=T)
    if(is.finite(m))
        m
    else
        default
} 