context("sharepoint-client")

test_that("sharepoint client can initialize a connection", {
  ## Mock out sharepoint interactions
  security_token_res <- readRDS("mocks/security_token_response.rds")
  cookies_res <- readRDS("mocks/cookies_response.rds")
  mock_post <- mockery::mock(security_token_res, cookies_res)

  withr::with_envvar(
    c("SHAREPOINT_USERNAME" = "user", "SHAREPOINT_PASS" = "pass"),
    with_mock("httr::POST" = mock_post, {
      client <- sharepoint_client$new("https://example.com")
    })
  )

  mockery::expect_called(mock_post, 2)
  args <- mockery::mock_args(mock_post)[[1]]
  expect_equal(args[[1]],
               "https://login.microsoftonline.com/extSTS.srf")
  expect_true(grepl("<o:Username>user</o:Username>", args[[2]]))
  expect_true(grepl("<o:Password>pass</o:Password>", args[[2]]))
  expect_true(grepl("<a:Address>https://example.com</a:Address>", args[[2]]))

  args <- mockery::mock_args(mock_post)[[2]]
  expect_equal(args[[1]],
               "https://example.com/_forms/default.aspx?wa=wsignin1.0")
  expect_equal(args[[2]], "t=EXAMPLE_TOKEN==&p=")
  ## Handle has been setup to use sharepoint URL
  expect_s3_class(args[[3]], "handle")
  expect_equal(args[[3]]$url, "https://example.com")
})

test_that("sharepoint client caches cookies between requests", {
  client <- mock_sharepoint_client("https://httpbin.org")

  res <- client$GET("/cookies/set/test_cookie/123")
  cookies <- httr::cookies(res)
  expect_equal(cookies$name, "test_cookie")
  expect_equal(cookies$value, "123")

  ## client sends cookies on subsequent requests
  res <- client$GET("/cookies")
  content <- httr::content(res)
  expect_equal(content,
               list(cookies = list(
                 test_cookie = "123"
               )
  ))
})

test_that("client returns useful error if authentication fails",  {
  withr::with_envvar(
    c("SHAREPOINT_USERNAME" = "user", "SHAREPOINT_PASS" = "pass"),
    expect_error(sharepoint_client$new("https://httpbin.org"),
                 "Failed to retrieve security token for user 'user'.")
  )

  mock_post <- mockery::mock(list(status_code = 400))

  withr::with_envvar(
    c("SHAREPOINT_USERNAME" = "user", "SHAREPOINT_PASS" = "pass"),
    with_mock("httr::POST" = mock_post, {
      expect_error(sharepoint_client$new("https://httpbin.org"),
                   "Failed to authenticate user 'user'.")
    })
  )
})

test_that("can construct security token payload", {
  creds <- list(
    username = "user@example.com",
    password = "password123"
  )
  payload <- prepare_security_token_payload("https://example.com", creds)

  expect_true(grepl("<o:Username>user@example.com</o:Username>", payload))
  expect_true(grepl("<o:Password>password123</o:Password>", payload))
  expect_true(grepl("<a:Address>https://example.com</a:Address>", payload))
})

test_that("can get security token from response", {
  res <- readRDS("mocks/security_token_response.rds")
  token <- parse_security_token_response(res)

  expect_equal(token, "t=EXAMPLE_TOKEN==&p=")
})

test_that("can validate cookies",  {
  cookies_res <- readRDS("mocks/cookies_response.rds")
  expect_true(validate_cookies(cookies_res))

  test_cookies <- httr::GET("https://httpbin.org/cookies/set/test/123")
  test_cookies <- httr::GET("https://httpbin.org/cookies/set/test2/example")
  expect_error(validate_cookies(test_cookies),
  "Failed to retrieve all required cookies from URL 'https://httpbin.org/cookies'.
Must provide rtFa and FedAuth cookies, got test, test2", fixed = TRUE)
})


## This is particularly ugly to set, unfortunately
test_that("can retrieve auth cookies", {
  ## Create the client in a way that sets cookies:
  client <- mock_sharepoint_client("https://httpbin.org", TRUE)

  d <- client$get_auth_data()
  expect_is(d, "raw")
  dat <- unserialize(d)
  expect_is(dat, "data.frame")
  expect_equal(dat$name, c("rtFa", "FedAuth"))
  expect_equal(dat$value, c("example_rtFa", "example_FedAuth"))

  p <- client$get_auth_data(tempfile())
  expect_true(file.exists(p))
  expect_identical(read_binary(p), d)
})


test_that("Can create a client with auth cookies", {
  dat <- data.frame(name = c("rtFa", "FedAuth"),
                    value = c("example_rtFa", "example_FedAuth"),
                    stringsAsFactors = FALSE)
  auth <- serialize(dat, NULL)

  cookies_res <- readRDS("mocks/cookies_response.rds")
  mock_post <- mockery::mock(cookies_res)

  client <- with_mock("httr::POST" = mock_post,
                      sharepoint_client$new("https://httpbin.org", auth))

  mockery::expect_called(mock_post, 1)
  args <- mockery::mock_args(mock_post)[[1]]
  expect_equal(args[[1]], "https://httpbin.org//_api/contextinfo")
  expect_equal(args[[2]], httr::accept_json())
  expect_equal(args[[3]], auth_to_cookies(auth))
  expect_equal(args[[4]], r6_private(client)$handle)

  expect_is(r6_private(client)$handle, "handle")
})


test_that("Can read auth data", {
  dat <- data.frame(name = c("rtFa", "FedAuth"),
                    value = c("example_rtFa", "example_FedAuth"),
                    stringsAsFactors = FALSE)
  auth <- serialize(dat, NULL)
  str <- paste(dat$name, dat$value, sep = "=", collapse = "; ")
  expected <- httr::config(cookie = str)
  tmp <- tempfile()
  writeBin(auth, tmp)

  expect_equal(auth_to_cookies(auth), expected)
  expect_equal(auth_to_cookies(tmp), expected)
  expect_error(auth_to_cookies(NULL))
  expect_error(auth_to_cookies(tempfile()))
})
