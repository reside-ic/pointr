#' Create sharepoint client, to manage HTTP requests to sharepoint.
#'
#' @keywords internal
#' @noRd
sharepoint_client <- R6::R6Class(
  "sharepoint_client",
  cloneable = FALSE,

  public = list(
    sharepoint_url = NULL,

    #' @description
    #' Create client object for sending http requests to sharepoint.
    #'
    #' This manages authenticating with sharepoint via sending credentails to
    #' microsoft to retrieve an access token which it then sends to sharepoint
    #' to retrieve cookies used for subsequent authentication.
    #'
    #' @param sharepoint_url Root URL of sharepoint site to download from
    #'
    #' @param auth Authentication data as returned by the
    #' \code{$get_auth_data()} method
    #'
    #' @return A new `sharepoint_client` object
    initialize = function(sharepoint_url, auth = NULL) {
      self$sharepoint_url <- sharepoint_url
      private$handle <- httr::handle(self$sharepoint_url)
      if (is.null(auth)) {
        self$login()
      } else {
        self$set_auth_data(auth)
      }
    },

    #' @description Login to sharepoint with username and password
    login = function() {
      creds <- get_credentials()
      response <- httr::POST(
        "https://login.microsoftonline.com/extSTS.srf",
        body = prepare_security_token_payload(self$sharepoint_url, creds))
      ## Not sure if this ever returns a non 200 response but left
      ## here to be safe. On failed auth it sends a different set of
      ## xml but still 200
      if (response$status_code != 200) {
        stop(sprintf("Failed to authenticate user '%s'.", creds$username))
      }
      ## Note that httr preserves cookies and settings over multiple
      ## requests via the handle. Means that if we auth once and
      ## retrieve cookies httr will automatically send these on
      ## subsequent requests if using the same handle object
      ##
      ## These tokens last for ~24h
      security_token <- parse_security_token_response(response)
      if (is.na(security_token)) {
        stop(sprintf("Failed to retrieve security token for user '%s'.",
                     creds$username))
      }
      res <- self$POST("_forms/default.aspx?wa=wsignin1.0",
                       body = security_token)
      validate_cookies(res)
    },

    #' @description
    #' Send GET request to sharepoint
    #'
    #' @param ... Args passed on to httr
    #'
    #' @return HTTP response
    GET = function(...) {
      self$request(httr::GET, ...)
    },

    #' @description
    #' Send POST request to sharepoint
    #'
    #' @param ... Args passed on to httr
    #'
    #' @param digest Argument passed through to \code{$digest()} to create
    #' the response digest; typically a site name
    #'
    #' @return HTTP response
    POST = function(..., digest = NULL) {
      if (!is.null(digest)) {
        digest <- self$digest(digest)
        self$request(httr::POST, ..., digest)
      } else {
        self$request(httr::POST, ...)
      }
    },

    #' @description
    #' Send DELETE request to sharepoint
    #'
    #' @param ... Args passed on to httr
    #'
    #' @param digest Argument passed through to \code{$digest()} to create
    #' the response digest; typically a site name
    #'
    #' @return HTTP response
    DELETE = function(..., digest) {
      self$request(httr::DELETE, ..., self$digest(digest))
    },

    #' @description
    #' Send POST request to sharepoint
    #'
    #' @param verb A httr function for type of request to send e.g. httr::GET
    #' @param path Request path
    #' @param ... Additional args passed on to httr
    #'
    #' @return HTTP response
    request = function(verb, path, ...) {
      url <- paste(self$sharepoint_url, path, sep = "/")
      verb(url, ..., handle = private$handle)
    },

    #' @description
    #' Get Sharepoint's "Request Digest" security feature.  This method
    #' sends a request to get the request digest for a given sharepoint
    #' site, which needs to be used in subsequent \code{POST} requests.
    digest = function(site) {
      url <- sprintf("/sites/%s/_api/contextinfo", site)
      r <- self$POST(url, httr::accept_json())
      httr::stop_for_status(r)
      dat <- response_from_json(r)
      httr::add_headers("X-RequestDigest" = dat$FormDigestValue)
    },

    #' @description
    #' Get the authentication data from the client.  If this is saved
    #' to a file it provides a way of re-authenticating with a server
    #' for a limited period (typically between a few days and a few
    #' weeks) without re-entering the username and password, and may be
    #' suitable for automated tasks.  Note that unlike proper OAuth-based
    #' access, there is no way of revoking such access and so the
    #' authentication data should be treated very carefully.
    #'
    #' @param file A file to write the data to. If \code{NULL} the raw data
    #' is returned directly.
    get_auth_data = function(file = NULL) {
      dat <- httr::cookies(private$handle)
      d <- serialize(
        dat[dat$name %in% c("rtFa", "FedAuth"), c("name", "value")],
        NULL)
      if (is.null(file)) {
        d
      } else {
        writeBin(d, file)
        file
      }
    },

    set_auth_data = function(auth) {
      cookies <- auth_to_cookies(auth)
      res <- self$POST("/_api/contextinfo", httr::accept_json(), cookies)
      httr::stop_for_status(res)
      validate_cookies(res)
    }
  ),

  private = list(
    handle = NULL
  )
)

#' Prepare payload for retrieving security token
#'
#' @param url URL for site you are requesting a token for
#' @param credentials Username and password for site request token
#'
#' @return Formatted xml body for security token request
#' @keywords internal
#' @noRd
prepare_security_token_payload <- function(url, credentials) {
  payload <- paste(readLines(spud_file("security_token_request.xml")),
                   collapse = "\n")
  glue::glue(payload, root_url = url,
             username = credentials$username,
             password = credentials$password)
}

#' Parse response from security token request
#'
#' This takes the full response and pulls out the part of the xml containing
#' the security token.
#'
#' @param response httr response object
#'
#' @return The security token or NA if failed to retrieve
#' @keywords internal
#' @noRd
parse_security_token_response <- function(response) {
  xml <- httr::content(response, "text", "text/xml", encoding = "UTF-8")
  parsed_xml <- xml2::read_xml(xml)
  token_node <- xml2::xml_find_first(parsed_xml, "//wsse:BinarySecurityToken")
  xml2::xml_text(token_node)
}

#' Validate cookies in response
#'
#' To be able to use cookies in subsequent requests to sharepoint we
#' require the rtFa and FedAuth cookies to be set
#'
#' @param response
#'
#' @return Invisible TRUE if valid, error otherwise
#' @keywords internal
#' @noRd
validate_cookies <- function(response) {
  cookies <- httr::cookies(response)
  if (!(all(c("rtFa", "FedAuth") %in% cookies$name))) {
    stop(sprintf("Failed to retrieve all required cookies from URL '%s'.
Must provide rtFa and FedAuth cookies, got %s",
                 response$url,
                 paste(cookies$name, collapse = ", ")))
  }
  invisible(TRUE)
}


auth_to_cookies <- function(auth) {
  if (is.character(auth)) {
    stopifnot(file.exists(auth))
    auth <- read_binary(auth)
  }
  stopifnot(is.raw(auth))
  auth <- unserialize(auth)
  string <- paste(auth$name, auth$value, sep = "=", collapse = "; ")
  httr::config(cookie = string)
}
