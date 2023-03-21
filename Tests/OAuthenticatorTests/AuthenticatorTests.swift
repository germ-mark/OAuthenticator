import XCTest
@testable import OAuthenticator

enum AuthenticatorTestsError: Error {
	case disabled
}

@MainActor
final class MockURLResponseProvider {
	var responses: [Result<(Data, URLResponse), Error>] = []
	private(set) var requests: [URLRequest] = []

	init() {
	}

	func response(for request: URLRequest) throws -> (Data, URLResponse) {
		requests.append(request)

		return try responses.removeFirst().get()
	}

	var responseProvider: URLResponseProvider {
		return { try self.response(for: $0) }
	}
}

final class AuthenticatorTests: XCTestCase {
	private static let mockCredentials = AppCredentials(clientId: "abc",
														clientPassword: "def",
														scopes: ["123"],
														callbackURL: URL(string: "my://callback")!)

	private static let disabledUserAuthenticator: Authenticator.UserAuthenticator = { _, _ in
		throw AuthenticatorTestsError.disabled
	}

	private static let disabledAuthorizationURLProvider: TokenHandling.AuthorizationURLProvider = { _ in
		throw AuthenticatorTestsError.disabled
	}

	private static let disabledLoginProvider: TokenHandling.LoginProvider = { _, _, _, _ in
		throw AuthenticatorTestsError.disabled
	}

	private func compatFulfillment(of expectations: [XCTestExpectation], timeout: TimeInterval, enforceOrder: Bool) async {
#if compiler(>=5.8)
		await fulfillment(of: expectations, timeout: timeout, enforceOrder: enforceOrder)
#else
		await Task {
			wait(for: , timeout: timeout, enforceOrder: enforceOrder)
		}.value
#endif
	}

	func testInitialLogin() async throws {
		let authedLoadExp = expectation(description: "load url")

		let mockLoader: URLResponseProvider = { request in
			XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer TOKEN")
			authedLoadExp.fulfill()

			return ("hello".data(using: .utf8)!, URLResponse())
		}

		let userAuthExp = expectation(description: "user auth")
		let mockUserAuthenticator: Authenticator.UserAuthenticator = { url, scheme in
			userAuthExp.fulfill()
			XCTAssertEqual(url, URL(string: "my://auth?client_id=abc")!)
			XCTAssertEqual(scheme, "my")

			return URL(string: "my://login")!
		}

		let urlProvider: TokenHandling.AuthorizationURLProvider = { creds in
			return URL(string: "my://auth?client_id=\(creds.clientId)")!
		}

		let loginProvider: TokenHandling.LoginProvider = { url, creds, tokenUrl, _ in
			XCTAssertEqual(url, URL(string: "my://login")!)

			return Login(token: "TOKEN")
		}

		let tokenHandling = TokenHandling(authorizationURLProvider: urlProvider,
										  loginProvider: loginProvider,
										  responseStatusProvider: TokenHandling.allResponsesValid)

		let retrieveTokenExp = expectation(description: "get token")
		let storeTokenExp = expectation(description: "save token")

		let storage = LoginStorage {
			retrieveTokenExp.fulfill()

			return nil
		} storeLogin: {
			XCTAssertEqual($0, Login(token: "TOKEN"))

			storeTokenExp.fulfill()
		}

		let config = Authenticator.Configuration(appCredentials: Self.mockCredentials,
												 loginStorage: storage,
												 tokenHandling: tokenHandling,
												 userAuthenticator: mockUserAuthenticator)

		let auth = await Authenticator(config: config, urlLoader: mockLoader)

		let (_, _) = try await auth.response(for: URLRequest(url: URL(string: "https://example.com")!))

		await compatFulfillment(of: [retrieveTokenExp, userAuthExp, storeTokenExp, authedLoadExp], timeout: 1.0, enforceOrder: true)
	}

	func testExistingLogin() async throws {
		let authedLoadExp = expectation(description: "load url")

		let mockLoader: URLResponseProvider = { request in
			XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer TOKEN")
			authedLoadExp.fulfill()

			return ("hello".data(using: .utf8)!, URLResponse())
		}

		let tokenHandling = TokenHandling(authorizationURLProvider: Self.disabledAuthorizationURLProvider,
										  loginProvider: Self.disabledLoginProvider,
										  responseStatusProvider: TokenHandling.allResponsesValid)

		let retrieveTokenExp = expectation(description: "get token")
		let storage = LoginStorage {
			retrieveTokenExp.fulfill()

			return Login(token: "TOKEN")
		} storeLogin: { _ in
			XCTFail()
		}

		let config = Authenticator.Configuration(appCredentials: Self.mockCredentials,
												 loginStorage: storage,
												 tokenHandling: tokenHandling,
												 userAuthenticator: Self.disabledUserAuthenticator)

		let auth = await Authenticator(config: config, urlLoader: mockLoader)

		let (_, _) = try await auth.response(for: URLRequest(url: URL(string: "https://example.com")!))

		await fulfillment(of: [retrieveTokenExp, authedLoadExp], timeout: 1.0, enforceOrder: true)
	}

	func testExpiredTokenRefresh() async throws {
		let authedLoadExp = expectation(description: "load url")

		let mockLoader: URLResponseProvider = { request in
			XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer REFRESHED")
			authedLoadExp.fulfill()

			return ("hello".data(using: .utf8)!, URLResponse())
		}

		let refreshExp = expectation(description: "refresh")
		let refreshProvider: TokenHandling.RefreshProvider = { login, _, _ in
			XCTAssertEqual(login.accessToken.value, "EXPIRED")
			XCTAssertEqual(login.refreshToken?.value, "REFRESH")

			refreshExp.fulfill()

			return Login(token: "REFRESHED")
		}

		let tokenHandling = TokenHandling(authorizationURLProvider: Self.disabledAuthorizationURLProvider,
										  loginProvider: Self.disabledLoginProvider,
										  refreshProvider: refreshProvider,
										  responseStatusProvider: TokenHandling.allResponsesValid)

		let retrieveTokenExp = expectation(description: "get token")
		let storeTokenExp = expectation(description: "save token")

		let storage = LoginStorage {
			retrieveTokenExp.fulfill()

			return Login(accessToken: Token(value: "EXPIRED", expiry: .distantPast),
						 refreshToken: Token(value: "REFRESH"))
		} storeLogin: { login in
			storeTokenExp.fulfill()

			XCTAssertEqual(login.accessToken.value, "REFRESHED")
		}

		let config = Authenticator.Configuration(appCredentials: Self.mockCredentials,
												 loginStorage: storage,
												 tokenHandling: tokenHandling,
												 userAuthenticator: Self.disabledUserAuthenticator)

		let auth = await Authenticator(config: config, urlLoader: mockLoader)

		let (_, _) = try await auth.response(for: URLRequest(url: URL(string: "https://example.com")!))

		await compatFulfillment(of: [retrieveTokenExp, refreshExp, storeTokenExp, authedLoadExp], timeout: 1.0, enforceOrder: true)
	}

	func testManualAuthentication() async throws {
		let urlProvider: TokenHandling.AuthorizationURLProvider = { creds in
			return URL(string: "my://auth?client_id=\(creds.clientId)")!
		}

		let loginProvider: TokenHandling.LoginProvider = { url, creds, tokenUrl, _ in
			XCTAssertEqual(url, URL(string: "my://login")!)

			return Login(token: "TOKEN")
		}

		let tokenHandling = TokenHandling(authorizationURLProvider: urlProvider,
										  loginProvider: loginProvider,
										  responseStatusProvider: TokenHandling.allResponsesValid)

		let userAuthExp = expectation(description: "user auth")
		let mockUserAuthenticator: Authenticator.UserAuthenticator = { url, scheme in
			userAuthExp.fulfill()

			return URL(string: "my://login")!
		}

		let config = Authenticator.Configuration(appCredentials: Self.mockCredentials,
												 tokenHandling: tokenHandling,
												 mode: .manualOnly,
												 userAuthenticator: mockUserAuthenticator)

		let loadExp = expectation(description: "load url")
		let mockLoader: URLResponseProvider = { request in
			loadExp.fulfill()

			return ("hello".data(using: .utf8)!, URLResponse())
		}

		let auth = await Authenticator(config: config, urlLoader: mockLoader)

		do {
			let (_, _) = try await auth.response(for: URLRequest(url: URL(string: "https://example.com")!))

			XCTFail()
		} catch AuthenticatorError.manualAuthenticationRequired {

		} catch {
			XCTFail()
		}

		// now we explicitly authenticate, and things should work
		try await auth.authenticate()

		let (_, _) = try await auth.response(for: URLRequest(url: URL(string: "https://example.com")!))
		
		await compatFulfillment(of: [userAuthExp, loadExp], timeout: 1.0, enforceOrder: true)
	}

	@MainActor
	func testUnauthorizedRequestRefreshes() async throws {
		let requestedURL = URL(string: "https://example.com")!

		let mockLoader = MockURLResponseProvider()
		let mockData = "hello".data(using: .utf8)!

		mockLoader.responses = [
			.success((Data(), HTTPURLResponse(url: requestedURL, statusCode: 401, httpVersion: nil, headerFields: nil)!)),
			.success((mockData, HTTPURLResponse(url: requestedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)),
		]

		let refreshProvider: TokenHandling.RefreshProvider = { login, _, _ in
			return Login(token: "REFRESHED")
		}

		let tokenHandling = TokenHandling(authorizationURLProvider: Self.disabledAuthorizationURLProvider,
										  loginProvider: Self.disabledLoginProvider,
										  refreshProvider: refreshProvider)

		let storage = LoginStorage {
			// ensure we actually try this one
			return Login(accessToken: Token(value: "EXPIRED", expiry: .distantFuture),
						 refreshToken: Token(value: "REFRESH"))
		} storeLogin: { login in
			XCTAssertEqual(login.accessToken.value, "REFRESHED")
		}

		let config = Authenticator.Configuration(appCredentials: Self.mockCredentials,
												 loginStorage: storage,
												 tokenHandling: tokenHandling,
												 userAuthenticator: Self.disabledUserAuthenticator)

		let auth = Authenticator(config: config, urlLoader: mockLoader.responseProvider)

		let (data, _) = try await auth.response(for: URLRequest(url: requestedURL))

		XCTAssertEqual(data, mockData)
		XCTAssertEqual(mockLoader.requests.count, 2)
		XCTAssertEqual(mockLoader.requests[0].allHTTPHeaderFields!["Authorization"], "Bearer EXPIRED")
		XCTAssertEqual(mockLoader.requests[1].allHTTPHeaderFields!["Authorization"], "Bearer REFRESHED")
	}
}
