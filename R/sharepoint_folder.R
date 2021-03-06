## There are lots of details that are not exposed here yet, in
## particular, see
##
## https://docs.microsoft.com/en-us/previous-versions/office/sharepoint-csom/ee542189(v=office.15)
##
## which seems to be the documentation for the underlying code that
## the API is built on top of

#' Interact with sharepoint folders and their files.
sharepoint_folder <- R6::R6Class(
  "sharepoint_folder",
  cloneable = FALSE,

  private = list(
    client = NULL
  ),

  public = list(
    #' @field site Name of the sharepoint site (readonly)
    site = NULL,

    #' @field path Path of the folder (readonly)
    path = NULL,

    #' @description Create sharepoint_folder object to enable listing, creating
    #' downloading and uploading files & folders
    #' @param client A low-level sharepoint client object, which can be used to
    #' interact directly with the sharepoint API.
    #' @param site The name of the sharepoint site (most likely a short string)
    #' @param path Relative path within that shared site.  It seems
    #' that "Shared Documents" is a common path that most likely
    #' represents a "Documents" collection when viewed in the
    #' sharepoint web interface.
    #' @param verify Logical, indicating if the site/path combination is
    #' valid (slower but safer).
    initialize = function(client, site, path, verify = FALSE) {
      stopifnot(inherits(client, "sharepoint_client"))
      private$client <- client
      self$site <- site
      self$path <- path

      if (verify) {
        r <- private$client$GET(sharepoint_folder_url(site, path))
        if (httr::status_code(r) == 404) {
          stop(sprintf("Path '%s' was not found on site '%s'", path, site),
               call. = FALSE)
        }
        httr::stop_for_status(r)
      }

      lockBinding("site", self)
      lockBinding("path", self)
    },

    #' @description List all files within the folder
    #' @param path Folder relative to this folder, uses this folder if NULL
    files = function(path = NULL) {
      url <- sprintf(
        "/sites/%s/_api/web/GetFolderByServerRelativeURL('%s')/files",
        self$site, URLencode(file_path2(self$path, path)))
      r <- private$client$GET(url)
      httr::stop_for_status(r)
      dat <- response_from_json(r)
      ## NOTE: Despite the reference saying it should be a long, we
      ## get size as a string
      tibble::tibble(
        name = vcapply(dat$value, "[[", "Name"),
        size = as.numeric(vcapply(dat$value, "[[", "Length")),
        created = to_time(vcapply(dat$value, "[[", "TimeCreated")),
        modified = to_time(vcapply(dat$value, "[[", "TimeLastModified")))
    },

    #' @description List all folders within the folder
    #' @param path Folder relative to this folder, uses this folder if NULL
    folders = function(path = NULL) {
      url <- sprintf(
        "/sites/%s/_api/web/GetFolderByServerRelativeURL('%s')/folders",
        self$site, URLencode(file_path2(self$path, path)))
      r <- private$client$GET(url)
      httr::stop_for_status(r)
      dat <- response_from_json(r)
      tibble::tibble(
        name = vcapply(dat$value, "[[", "Name"),
        items = vnapply(dat$value, "[[", "ItemCount"),
        created = to_time(vcapply(dat$value, "[[", "TimeCreated")),
        modified = to_time(vcapply(dat$value, "[[", "TimeLastModified")))
    },

    #' @description List all folders and files within the folder; this is a
    #' convenience wrapper around the \code{files} and \code{folders} methods.
    #' @param path Folder relative to this folder, uses this folder if NULL
    list = function(path = NULL) {
      folders <- self$folders(path)
      files <- self$files(path)
      folders$size <- rep(NA_real_, nrow(folders))
      folders$is_folder <- TRUE
      files$items <- rep(NA_integer_, nrow(files))
      files$is_folder <- FALSE
      v <- c("name", "items", "size", "is_folder", "created", "modified")
      rbind(folders[v], files[v])
    },

    #' @description Delete a folder. Be extremely careful as you could
    #' use this to delete an entire sharepoint. Deleted files are sent
    #' to the recycle bin, so can be restored with relative ease, but
    #' it will still be alarming. There is a mechanism to prevent
    #' accidental deletion by declaring a file that exists within the
    #' folder.
    #'
    #' @param path The path to delete. Use \code{NULL} to delete the current
    #'   folder.
    #'
    #' @param check A file (not folder) that exists directly within
    #'   \code{path}, used as a method to verify that you really do want
    #'   to delete this folder (to prevent things like accidental deletion
    #'   of the entire sharepoint, for example).
    delete = function(path, check) {
      if (!(check %in% self$files(path)$name)) {
        stop(sprintf(
          "The file '%s' was not found in the folder to delete '%s'",
          check, path))
      }
      url <- sprintf(
        "/sites/%s/_api/web/GetFolderByServerRelativeURL('%s')/recycle()",
        self$site, URLencode(file_path2(self$path, path)))
      headers <- httr::add_headers(
        "If-Match" = "{etag or *}")
      r <- private$client$DELETE(url, headers, digest = self$site)
      httr::stop_for_status(r)
      invisible()
    },

    #' @description Create an object referring to the parent folder
    #' @param verify Verify that the folder exists (which it must really here)
    parent = function(verify = FALSE) {
      sharepoint_folder$new(private$client, self$site,
                            dirname(self$path), verify)
    },

    #' @description Create an object referring to a child folder
    #' @param path The name of the folder, relative to this folder
    #' @param verify Verify that the folder exists (which it must really here)
    folder = function(path, verify = FALSE) {
      sharepoint_folder$new(private$client, self$site,
                            file.path(self$path, path), verify)
    },

    #' @description Create a folder on sharepoint
    #' @param path Folder relative to this folder
    create = function(path) {
      url <- sprintf("sites/%s/_api/web/folders", self$site)

      ## We have to use the content type
      ## "application/json;odata=verbose" here and not plain
      ## "application/json" otherwise we get a 400 Bad Request error.
      path_full <- file.path(self$path, path)
      body <- as.character(jsonlite::toJSON(
        list("__metadata" = list(type = jsonlite::unbox("SP.Folder")),
             ServerRelativeUrl = jsonlite::unbox(path_full))))
      headers <- httr::add_headers(
        "Content-Type" = "application/json;odata=verbose",
        "Accept" = "application/json;odata=verbose")

      r <- private$client$POST(url, body = body, headers,
                               digest = self$site, encode = "raw")
      httr::stop_for_status(r)
      invisible(self$folder(path, FALSE))
    },

    #' @description Download a file from a folder
    #' @param path The name of the path to download, relative to this folder
    #' @param dest Path to save downloaded data to. If \code{NULL} then a
    #'   temporary file with the same file extension as \code{path} is used.
    #'   If code{raw()} (or any other raw value) then the raw bytes will be
    #'   returned.
    #' @param progress Display httr's progress bar?
    #' @param overwrite Overwrite the file if it exists?
    download = function(path, dest = NULL, progress = FALSE,
                        overwrite = FALSE) {
      url <- sprintf(
        "%s/Files('%s')/$value",
        sharepoint_folder_file_url(self$site, self$path, path),
        URLencode(basename(path)))
      path_show <- sprintf("%s:%s/%s", self$site, self$path, path)
      download(private$client, url, dest, path_show, progress, overwrite)
    },

    #' @description Upload a file into a folder
    #' @param path The name of the path to upload, absolute, or relative to
    #' R's working directory.
    #' @param dest Remote path save downloaded data to, relative to this
    #' folder.  If \code{NULL} then the basename of the file is used.
    #' @param progress Display httr's progress bar?
    upload = function(path, dest = NULL, progress = FALSE) {
      opts <- if (progress) httr::progress("up") else NULL
      dest <- dest %||% basename(path)
      url <- sprintf(
        "%s/Files/Add(url='%s',overwrite=true)",
        sharepoint_folder_file_url(self$site, self$path, dest),
        URLencode(basename(dest)))
      body <- httr::upload_file(path, "application/octet-stream")
      r <- private$client$POST(url, body = body, opts,
                               digest = self$site)
      httr::stop_for_status(r)
      invisible()
    }
  ))


sharepoint_folder_url <- function(site, folder) {
  sprintf("/sites/%s/_api/web/GetFolderByServerRelativeURL('%s')",
          site, URLencode(folder))
}


sharepoint_folder_file_url <- function(site, folder, path) {
  filename <- basename(path)
  if (filename != path) {
    folder <- file.path(folder, dirname(path))
  }
  sharepoint_folder_url(site, folder)
}
