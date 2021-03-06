#' @include bhlm_classes.R
#' @include bhlm_helpers.R
#'
#' @import tidyverse
#' @import plyr
#' @import R2jags
NULL

#'@title Bayesian Hierarchical Latent Mixture Model
#'@description Run a BHLM model with custom number of latent variables according to specified number of outcome options.
#'The model sets priors for each outcome, group mean (theta) and estimate variance.
#'
#'Run following for model specification (Graphical notation):
#'
#'  \code{plot(0:1,0:1,type="n",ann=F,axes=F)}
#'  \code{rasterImage(bhlm_model_spec,0,0,1,1)}
#'
#' @author Hugh Benjamin Zachariae
#' @export
#' @param dataframe A data frame with studies, two grouping factor cols (e.g. studies*outcomes),
#' estimates, and optional ID column.
#' @param grouping_factor_cols A data vector of two grouping factor columns of the data frame
#'  (e.g. \code{c("Study", "Outcome")}). These columns must be integer vectors.
#' @param estimate_col Column of estimates in the data frame.
#' @param outcome_options_col Column containing the different outcome names
#'
#'  \code{Outcomes : Factor w/ 3 levels "Physical","Psychological",..: 2 2 2 2 2 2 2 2 1 1 ...}
#'
#' @param outcome_options Chosen outcomes. You can choose a subset of outcomes.
#' @param outcome_priors Priors for outcomes. Takes character vector or \code{matrix}.
#'
#'  Define all outcome priors to one distribution set prior (throws Warning) as \code{character}:
#'
#'  \code{"dnorm(0, 1)"}
#'
#'  \emph{Priors defined as character strings are checked with regex:}
#'
#'  \code{grepl("^[a-zA-Z]+\\(((\\d*\\.)*\\d+,\\s?)*(\\d*\\.)*\\d+\\)", .)}
#'
#'  or as data vector
#'
#'    \code{c("dnorm", 0, 1)}
#'
#'  Define all outcome priors manually with \code{matrix}. \strong{Notice}: byrow = T
#'
#'  \code{matrix(c("dnorm", 0, 1, "dnorm", 0, 1.1),
#'  nrow = 'number of outcomes',
#'  ncol = 'maximum amount of dist parameters',
#'  byrow = T)}
#'
#'  or as character vector of \code{characters}
#'
#'  \code{c("dnorm(0,1)", "dnorm(0,1.1)")}
#'
#'  \strong{Notice}: priors set manually, are set in the same order as \code{outcome_options}
#'  in character vector or in matrix row order (top to bottom).
#'
#' @param lambda_prior Prior for Lambda as \code{character} or data vector.
#' @param theta_prior Prior for Theta as \code{character} or data vector.
#' @param field_theta Optional: Include a another hierarchical level in the form of a field-wide mean distribution.
#' Use a string vector with the same distribution as \code{theta_prior} and precision (no mean). The field-wide mean prior,
#' is set to \code{theta_prior}. This solution is currently a fix-up, and should only be used on a case by case basis.
#' @param identifier_col ID column. Chosen column is added to the used data for easier overview.
#' @param bayes_method Use JAGS or STAN (currently only JAGS is implemented).
#' @param jags Parameters for \code{R2jags::\link[R2jags]{jags}}:
#'
#'   \code{init} (\code{NULL} set as default), \code{chains},
#'  \code{iter} (iterations per chain), \code{burning} (length of burn), \code{thin} (sim thinning rate), and
#'  \code{DIC} (compute deviance, pD and DIC).
#' @param save_model Input F to not save the model file,
#' NULL to save as 'model_file.txt' in working directory, or
#' filepath location with name to save the model file as .txt (Separated with '\\' or '/').
#'
#' @examples
#'
#' # INCOMING
#'
#'
bhlm <- function(dataframe,
                 grouping_factor_cols,
                 estimate_col,
                 outcome_options_col,
                 outcome_options,
                 outcome_priors,
                 lambda_prior,
                 theta_prior,
                 field_theta_precision = NULL,
                 identifier_col = NULL,
                 bayes_method = "jags",
                 jags_init = NULL, jags_chains=3, jags_iter = 2000,
                 jags_burnin = floor(jags_iter/2),
                 jags_thin = max(1, floor(jags_chains * (jags_iter-jags_burnin) / 1000)),
                 jags_DIC = T,
                 save_model = NULL
                 ) {

  if (length(outcome_options) <= 1) {
    stop(paste("Not enough outcomes, found ", length(outcome_options),
               ", required at least two.", sep = ""), call. = F)
  }


  if (!all(outcome_options %in% levels(dataframe[,outcome_options_col]))) {
    stop("One or more outcome names are not in outcome_option_col0", call. = F)
  }

  if(bayes_method == "jags") {

    tryCatch({

    data <- bhlm.preprocessing(dataframe,
                               grouping_factor_cols,
                               estimate_col,
                               outcome_options_col,
                               outcome_options,
                               identifier_col = identifier_col)

    }, error = function(e) {

      stop(paste("Preprocessing:", e), call. = F)

    })

# Create objects needed for model and jags ----------------------------------------------

    outcomes = as.vector(data@used_data$outcomes)
    outcomes_numeric = as.vector(data@used_data$outcomes_numeric)
    start_bounds = data@start_bounds
    upper_group = length(start_bounds) - 1

    jags_data <- c("outcomes", "outcomes_numeric", "start_bounds", "upper_group")
    result_parameters <- c(c("lambda", "theta"), outcome_options)

# Convert outcome priors ------------------------------------------------------

    dist_check <- "^[a-zA-Z]+\\(((\\d*\\.)*\\d+,\\s?)*(\\d*\\.)*\\d+\\)"
    outcome_priors_c <- "NULL"
    outcome_priors_m <- as.matrix("NULL")

    # Matrix (all outcome prior defined by list c("dist", n, n))
    if (class(outcome_priors) == "matrix") {
      if (length(outcome_priors[,1]) != length(outcome_options)) {
        stop(paste("Wrong number of priors, found ",
                   length(outcome_priors[,1]),
                   ", requires ", length(outcome_options),
                   " priors defined.\n  For full outcome prior defined, use: \n",
                   "  matrix(outcome_priors, nrow = length(outcome_options), ",
                   "ncol = 'distribution + max(parameters)', byrow = T)",
                   sep = ""),
             call. = F)
      } else {
        outcome_priors_new <- outcome_priors
        outcome_priors_m <- cbind(outcome_options, outcome_priors_new)
      }
    # c(...) or single string/character
    } else if (class(outcome_priors) == "character" || class(outcome_priors) == "string" ) {
      # If c(...)
      if (length(outcome_priors) > 1) {
        # If c("dist", n, n)
        if (!grepl("[^0-9]", outcome_priors[2])) {
          warning(paste("Only one outcome prior defined as vector, c(",
                        paste(outcome_priors, collapse = ", "),
                        "). All outcomes are set to have this prior.",
                        sep = "")
                  )
          outcome_priors_new <- matrix(outcome_priors,
                                       length(outcome_options),
                                       ncol = 3, byrow = T)
          outcome_priors_m <- cbind(outcome_options, outcome_priors_new)
        # Else c("dnorm(0, 1)", ...) (all outcome priors defined)
        } else {
          # Check that all prior distributions are well defined
          if (!all(grepl(dist_check, outcome_priors))) {
            stop(paste("Error in one of the defined outcome prior distributions.\n  ",
                 paste(outcome_priors, collapse = "\n"),
                 sep = ""), call. = F)
          }
          if (length(outcome_priors) != length(outcome_options)) {
            stop(paste("You have defined more than one outcome prior, but not all. Found ",
                       length(outcome_priors), " priors defined, requires ",
                       length(outcome_options), ".", sep = ""))
          } else {
            outcome_priors_new <- outcome_priors
            outcome_priors_c <- paste(outcome_options, outcome_priors_new, sep = "#")
          }
        }
        # Else only one string (all outcomes get same prior.)
      } else {
        if (!grepl(dist_check, outcome_priors)) {
          stop(paste("Error in the defined outcome prior distribution.\n",
                     outcome_priors,
                     sep = ""), call. = F)
        } else {
          warning(paste("Only one outcome prior defined as string, '",
                        outcome_priors,
                        "'. All outcomes are set to have this prior.",
                        sep = ""))
          outcome_priors_new <- rep(outcome_priors, length(outcome_options))
          outcome_priors_c <- paste(outcome_options, outcome_priors_new, sep = "#")
        }
      }
    } else {
      stop(paste("Unknown outcome priors setup, found ",
                 class(outcome_priors),
                 ".\n  oucome_priors has following setups: \n  ",
                 "One prior for all",
                 sep = ""), call. = F)
    }

# Create model file -----------------------------------------------------------

    tryCatch({

      modelfilepath = bhlm.write.model(
        bhlm.create.model.list(outcomes_list = outcome_options,
                               theta_prior = theta_prior,
                               lambda_prior = lambda_prior,
                               outcome_priors = outcome_priors_new,
                               field_theta = field_theta_precision),
        path = save_model)

    }, error = function(e) {

      stop(paste("Model creation:", e), call. = F)

    })

    tryCatch({

      samples = R2jags::jags(jags_data, inits = jags_init, result_parameters,
                             model.file = modelfilepath, n.chains=jags_chains, n.iter=jags_iter,
                             n.burnin=jags_burnin, n.thin=jags_thin, DIC=jags_DIC)

    }, error = function(e) {

      stop(paste("JAGS model sampling: ",
                 "\n  For Syntax error, consider saving model",
                 " file by setting a path for 'save_model'.\n  ", e,
                 sep = ""), call. = F)

    })
  }

  return(new("bhlm_object",
             used_data = data@used_data,
             start_bounds = data@start_bounds,
             jags_samples = samples,
             outcome_options = outcome_options,
             outcome_priors_m = outcome_priors_m,
             outcome_priors_c = outcome_priors_c,
             estimate_name = estimate_col))

}

#'@title Maximum a posteriori
#'@description Create a dataframe with outcome names, and maximum posteriori for each outcome.
#'You can choose the density estimation method (\code{polspline::logspline} or \code{base::density}).
#'
#' @author Hugh Benjamin Zachariae
#' @param bhlm_object Object returned from \code{bhlm}, of class \code{bhlm_object}.
#' @param outcome_options Character vector specifying which outcomes should be plotted.
#'   Defaults to all outcome options from \code{bhlm_object@outcome_options}.
#' @param density.estimate Choose between \code{polspline::logspline} or \code{base::density} for density estimation method.
#' @export

bhlm.MAP <- function (bhlm_object, outcome_options = NULL, density_estimate = "logspline") {

  if (class(bhlm_object) != "bhlm_object") {
    stop(paste("Not bhlm_object. Found ", class(bhlm_object), ".", sep = ""), call. = F)
  }

  if (is.null(outcome_options)) {
    outcome_options <- bhlm_object@outcome_options
  }

  data <- bhlm_object@jags_samples$BUGSoutput$sims.list

  table <- plyr::ldply(1:length(outcome_options), function(p) {

    data.frame('Outcome' = outcome_options[p],
               "MAP" = density(data[[outcome_options[p]]])$x[which(density(data[[outcome_options[p]]])$y==max(density(data[[outcome_options[p]]])$y))])

  })

  if (density_estimate == "logspline") {

    table <- plyr::ldply(outcome_options, function(o) {

      log.est <- logspline(data[o])

      u1 <- qlogspline(0.01, log.est)
      u2 <- qlogspline(0.99, log.est)
      u3 <- 1.1 * u1 - 0.1 * u2
      u4 <- 1.1 * u2 - 0.1 * u1

      d <- data.frame(x = (0:(1000 - 1))/(1000 - 1) * (u4 - u3) + u3) %>%
        mutate(y = dlogspline(x, log.est))

      return(data.frame('Outcome' = o,
                        'MAP' = d$x[which.max(d$y)]))
      })

    } else if (density_estimate == "density") {

    table <- plyr::ldply(1:length(outcome_options), function(o) {

      data.frame('Outcome' = outcome_options[o],
                 "MAP" = density(data[[outcome_options[o]]])$x[which(density(data[[outcome_options[o]]])$y==max(density(data[[outcome_options[o]]])$y))]) %>%
        as_tibble()
      })
    } else {
      stop("incorrect density estimation method", call. = F)
    }

  return(table)

}






