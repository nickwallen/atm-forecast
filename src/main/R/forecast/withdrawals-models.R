library("caret")
library("data.table")
library("logging")
library("foreach")
library("Metrics")
library("caretEnsemble")
library("plyr")

#
# create the feature set
#
buildFeatures <- function (split.at     = opts$splitAt,
                           history.file = opts$historyFile,
                           data.dir     = opts$dataDir, 
                           forecast.out = opts$forecastOut) {
    
    withd.cache <- sprintf("%s-features", basename.only(history.file))
    withd <- cache (withd.cache, {
        
        # fetch the withd history
        forecast.to = today() + forecast.out
        withd <- fetch (history.file, forecast.to, data.dir)
        
        # split and mark test versus training data
        split.at <- as.Date(split.at)
        withd [trandate <  split.at, train := 1, ]
        withd [trandate >= split.at, train := 0, ]
        
        # remove 'usage' from test data to prevent accidental 'bleed-through'
        withd.usage <- withd[, list(atm, trandate, usage.saved = usage)]
        withd [train == 0, usage := NA, ]
        
        # "actuals" cannot be trusted when a fault occurs; ignore them before building features
        faults (withd)
        
        # generate the feature set
        dates (withd)
        paydays (withd)
        holidays (withd)
        socialSecurity (withd)
        seasonalFactorBy (withd, "seasonal.woy", quote (c("atm", "week.of.year")))
        seasonalFactorBy (withd, "seasonal.moy", quote (c("atm", "month.of.year")))
        seasonalFactorBy (withd, "seasonal.dow", quote (c("atm", "day.of.week")))
        seasonalFactorBy (withd, "seasonal.wom", quote (c("atm", "week.of.month")))
        seasonalFactorBy (withd, "seasonal.qua", quote (c("atm", "quarter")))
        seasonalFactorBy (withd, "seasonal.hol", quote (c("atm", "holiday")))
        seasonalFactorBy (withd, "seasonal.pay", quote (c("atm", "payday")))
        sequence (withd)
        
        # add the 'usage' back into the feature set
        setkeyv (withd, c("atm", "trandate"))
        setkeyv (withd.usage, c("atm", "trandate"))
        withd [withd.usage, usage := usage.saved]
        
        # validate the feature set
        validate (withd)
        
        loginfo("completed building feature set: [%s x %s]", nrow(withd), ncol(withd))
        withd
    })
}

#
# jumps through some extra hoops like replacing NAs
#
findCorrelation <- function(x, use = "pairwise.complete.obs", ...) {
    
    # generate a correlation matrix with no NAs
    cor.mx <- cor (x, use = use)
    cor.mx [is.na(cor.mx)] <- 0
    
    # allow caret to do the hard part
    caret::findCorrelation(cor.mx)
}

#
# train the model
#
withd.train <- function (by, data.x, data.y, train.index, data.id) {
    fit <- NULL
    
    # cache the trained model
    fit.cache <- sprintf ("%s-challenger-%s", data.id, by)
    fit <- cache (fit.cache, {
        loginfo("[%s] pre-processing: [%s x %s]", by, nrow(data.x), ncol(data.x))
        features.before <- colnames (data.x)
        
        # remove features that are highly correlated or with little/no variance
        data.x <- data.x[, -nearZeroVar (data.x)]
        data.x <- data.x[, -findCorrelation (data.x)]
        logdebug ("[%s] low variance/correlation detected: %s", by, sort (setdiff (features.before, colnames (data.x))))
        
        # split the training and test data
        train.x <- data.x [  train.index, ]
        train.y <- data.y [  train.index  ]
        test.x  <- data.x [ -train.index, ]
        test.y  <- data.y [ -train.index  ]
        
        # if no training data, or training response all 0s then don't train
        loginfo("[%s] training: [%s x %s]", by, nrow(train.x), ncol(train.x))
        if (nrow (train.x) > 0 && any (train.y > 0)) {
            max.prediction <- max (train.y, na.rm = T) + 4 * sd (train.y, na.rm = T)
            folds <- 5
            
            # default args for each of the models
            args.default = list (
                x          = train.x, 
                y          = train.y, 
                
                # defines pre-processing 
                preProcess = c("center", "scale", "knnImpute"),
                
                # defines how tuning/training should occur
                trControl  = trainControl (
                    method           = "cv",
                    number           = folds,
                    classProbs       = T,
                    returnData       = F,
                    savePredictions  = T,
                    allowParallel    = T,
                    verbose          = F,
                    returnResamp     = "none", 
                    predictionBounds = c(0, max.prediction),
                    index            = createFolds (train.y, k = folds)
                )
            )
            
            # define each of the challenger models
            args.custom <- list ( 
                #list (method = "gbm", verbose = F),
                list (method = "leapForward", warn.dep = F)
                #list (method = "glmboost")
                #list (method = "lasso"),
                #list (method = "knn")
            )
            
            # train each of the challengers; ignore any training failures
            challengers <- lapply.ignore (args.custom, function (args) { 
                do.call (caret::train, append (args.default, args))
            })
            loginfo ("[%s] trained '%s' model(s) for ensembling", by, length (challengers))
            
            # create a greedy ensemble 
            if (length (challengers) > 0) {
                fit <- caretEnsemble (challengers, iter = 1000L)
            } 
        }
    })
    
    if (!is.null(fit)) {
        loginfo ("[%s] ensemble chosen with rmse: %.2f models: %s", by, fit$error, format.wide (sort (fit$weights, decreasing = T)))        
    } else {
        stop ( sprintf ("[%s] unable to successfully build any models", by))
    }
    
    return (fit)
}

#
# makes predictions based on a fitted model
#
withd.predict <- function (by, fit, data.x, default.predict = 0) {
    
    # the default prediction, just in case shit hits the fan
    prediction <- rep (default.predict, nrow (data.x))
    if (!is.null (fit)) {
        
        # extract only the features used to train the model
        feature.names <- fit$models[[1]]$finalModel$xNames
        data.x <- data.x [, feature.names]
        
        # make a prediction - predict for all test/train
        prediction <- getOrElse( round (predict (fit, newdata = data.x)), 
                                 default.predict )
    }
    
    loginfo("[%s] prediction: [%s x %s]: %s", by, nrow (data.x), ncol (data.x), format.wide (summary (prediction)))
    return (prediction)
}

#
# train the challenger and make a prediction for a specific ATM
#
trainThenPredict <- function (by, data, data.id, formula ) {
    
    by <- by[[1]]
    train.index <- which (data[["train"]] == 1)
    
    # create the design matrix
    frame <- model.frame (formula, data, na.action = na.pass)
    data.y <- model.response (frame)
    data.x <- model.matrix (formula, frame)
    
    # train and predict
    fit <- withd.train (by, data.x, data.y, train.index, data.id)
    pred <- withd.predict (by, fit, data.x)
    
    return (pred)
}

#
# train a challenger model.  this model uses GBM and performs centering
# and scaling of the 
#
challenger <- function (features, 
                        subset    = opts$subset, 
                        data.id   = basename.only (opts$historyFile)) {
    
    features [
        # include only those ATMs that pass the 'subset' expression
        eval (parse (text = subset)),
        
        # train and fit a model
        list (
            trandate,
            usage,
            usage.hat = trainThenPredict (.BY, .SD, data.id, usage ~ . -train),
            model     = "challenger"
        ),
        
        # training occurs independently for each ATM
        by = atm ] 
}
