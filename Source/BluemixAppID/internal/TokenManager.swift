/* *     Copyright 2016, 2017 IBM Corp.
 *     Licensed under the Apache License, Version 2.0 (the "License");
 *     you may not use this file except in compliance with the License.
 *     You may obtain a copy of the License at
 *     http://www.apache.org/licenses/LICENSE-2.0
 *     Unless required by applicable law or agreed to in writing, software
 *     distributed under the License is distributed on an "AS IS" BASIS,
 *     WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *     See the License for the specific language governing permissions and
 *     limitations under the License.
 */

import Foundation
import BMSCore
internal class TokenManager {

    private final var appid:AppID
    private final var registrationManager:RegistrationManager
    internal var latestAccessToken:AccessToken?
    internal var latestIdentityToken:IdentityToken?
    internal var latestRefreshToken:RefreshToken?

    internal static let logger = Logger.logger(name: AppIDConstants.TokenManagerLoggerName)
    internal init(oAuthManager:OAuthManager)
    {
        self.appid = oAuthManager.appId
        self.registrationManager = oAuthManager.registrationManager!
    }


    public func obtainTokensAuthCode(code:String, authorizationDelegate:AuthorizationDelegate) {
        TokenManager.logger.debug(message: "obtainTokens")

        guard let clientId = self.registrationManager.getRegistrationDataString(name: AppIDConstants.client_id_String), let redirectUri = self.registrationManager.getRegistrationDataString(arrayName: AppIDConstants.JSON_REDIRECT_URIS_KEY, arrayIndex: 0) else {
            TokenManager.logger.error(message: "Client not registered")
            authorizationDelegate.onAuthorizationFailure(error: .authorizationFailure("Client not registered"))
            return
        }

        let bodyParams = [
            AppIDConstants.JSON_CODE_KEY : code,
            AppIDConstants.client_id_String :  clientId,
            AppIDConstants.JSON_GRANT_TYPE_KEY : AppIDConstants.authorization_code_String,
            AppIDConstants.JSON_REDIRECT_URI_KEY : redirectUri
        ]
        retrieveTokens(bodyParams: bodyParams, tokenResponseDelegate: authorizationDelegate)
    }

    public func obtainTokensRoP(accessTokenString: String? = nil, username: String, password: String, tokenResponseDelegate: TokenResponseDelegate) {
        TokenManager.logger.debug(message: "obtainTokens - with resource owner password")

        var bodyParams = [
            AppIDConstants.JSON_USERNAME : username,
            AppIDConstants.JSON_PASSWORD :  password,
            AppIDConstants.JSON_GRANT_TYPE_KEY : AppIDConstants.resource_owner_password_String
        ]
        if accessTokenString != nil {
            bodyParams[AppIDConstants.APPID_ACCESS_TOKEN] = accessTokenString
        }

        retrieveTokens(bodyParams: bodyParams, tokenResponseDelegate: tokenResponseDelegate)

    }

    public func obtainTokensRefreshToken(refreshTokenString: String,
                                             tokenResponseDelegate: TokenResponseDelegate) {
        TokenManager.logger.debug(message: "obtainTokens - with resource owner password")

        let bodyParams = [
            AppIDConstants.JSON_REFRESH_TOKEN : refreshTokenString,
            AppIDConstants.JSON_GRANT_TYPE_KEY : AppIDConstants.refresh_token_String
        ]
        retrieveTokens(bodyParams: bodyParams, tokenResponseDelegate: tokenResponseDelegate)
    }

    internal func retrieveTokens(bodyParams: [String:String],  tokenResponseDelegate: TokenResponseDelegate) {
        let tokenUrl = Config.getServerUrl(appId: self.appid) + "/token"

        guard let clientId = self.registrationManager.getRegistrationDataString(name: AppIDConstants.client_id_String) else {
            TokenManager.logger.error(message: "Client not registered")
            tokenResponseDelegate.onAuthorizationFailure(error: .authorizationFailure("Client not registered"))
            return
        }

        var headers:[String:String] = [:]

        do {
            headers = [AppIDConstants.AUTHORIZATION_HEADER : try createAuthenticationHeader(clientId: clientId),
                       Request.contentType : "application/x-www-form-urlencoded"]
        } catch (_) {
            TokenManager.logger.error(message: "Failed to create authentication header")
            tokenResponseDelegate.onAuthorizationFailure(error: .authorizationFailure("Failed to create authentication header"))
            return
        }

        let internalCallback: BMSCompletionHandler = {(response: Response?, error: Error?) in
            if error == nil {
                if let unWrappedResponse = response, unWrappedResponse.isSuccessful {
                    self.extractTokens(response: unWrappedResponse, tokenResponseDelegate: tokenResponseDelegate)
                }
                else {
                    tokenResponseDelegate.onAuthorizationFailure(error: .authorizationFailure("Failed to extract tokens"))
                }
            } else {
                guard let response = response else {
                    tokenResponseDelegate.onAuthorizationFailure(error: .authorizationFailure("Failed to retrieve tokens"))
                    return
                }

                guard let errorText = response.responseText,
                    let errorJson = try? Utils.parseJsonStringtoDictionary(errorText) as? [String: String],
                    let errorDescription = errorJson?["error_description"] else {
                        tokenResponseDelegate.onAuthorizationFailure(error: .authorizationFailure("Failed to retrieve tokens"))
                        return
                }

                TokenManager.logger.debug(message: "Could not retrieve tokens - " +
                                                   "Status code: \(response.statusCode ?? -1 ) " +
                                                   "Response: \(errorText)")

                if response.statusCode == 400, errorJson?["error"] == "invalid_grant" {
                    tokenResponseDelegate.onAuthorizationFailure(error: .authorizationFailure(errorDescription))
                } else if response.statusCode == 403 {
                    tokenResponseDelegate.onAuthorizationFailure(error: .authorizationFailure(errorDescription))
                } else {
                    tokenResponseDelegate.onAuthorizationFailure(error: .authorizationFailure("Failed to retrieve tokens"))
                }
            }
        }

        let request = Request(url: tokenUrl,method: HttpMethod.POST, headers: headers, queryParameters: nil, timeout: 0)
        request.timeout = BMSClient.sharedInstance.requestTimeout
        var body = ""
        for (index, (key: key, value: value)) in bodyParams.enumerated() {
            body += "\(Utils.urlEncode(key))=\(Utils.urlEncode(value))"
            if index < bodyParams.count - 1 {
                body += "&"
            }
        }
        sendRequest(request: request, body: body.data(using: .utf8), internalCallBack: internalCallback)

    }

    internal func sendRequest(request:Request, body:Data?, internalCallBack: @escaping BMSCompletionHandler) {
        request.urlSession.isBMSAuthorizationRequest = true
        request.send(requestBody: body, completionHandler: internalCallBack)
    }


    public func extractTokens(response:Response, tokenResponseDelegate:TokenResponseDelegate) {
        TokenManager.logger.debug(message: "Extracting tokens from server response")

        guard let responseText = response.responseText else {
            TokenManager.logger.error(message: "Failed to parse server response - no response text")
            tokenResponseDelegate.onAuthorizationFailure(error: .authorizationFailure("Failed to parse server response - no response text"))
            return
        }
        do {
            var responseJson =  try Utils.parseJsonStringtoDictionary(responseText)

            guard let accessTokenString = (responseJson["access_token"] as? String), let idTokenString = (responseJson["id_token"] as? String) else {
                TokenManager.logger.error(message: "Failed to parse server response - no access or identity token")
                tokenResponseDelegate.onAuthorizationFailure(error: .authorizationFailure("Failed to parse server response - no access or identity token"))
                return
            }
            guard let accessToken = AccessTokenImpl(with: accessTokenString), let identityToken:IdentityTokenImpl = IdentityTokenImpl(with: idTokenString) else {
                TokenManager.logger.error(message: "Failed to parse tokens")
                tokenResponseDelegate.onAuthorizationFailure(error: .authorizationFailure("Failed to parse tokens"))
                return
            }
            let refreshTokenString = responseJson["refresh_token"] as? String
            var refreshToken: RefreshTokenImpl?
            if refreshTokenString != nil {
                refreshToken = RefreshTokenImpl(with: refreshTokenString!)
            }
            self.latestAccessToken = accessToken
            self.latestIdentityToken = identityToken
            self.latestRefreshToken = refreshToken
            tokenResponseDelegate.onAuthorizationSuccess(accessToken: accessToken,
                                                         identityToken: identityToken,
                                                         refreshToken: refreshToken,
                                                         response:response)
        } catch (_) {
            TokenManager.logger.error(message: "Failed to parse server response - failed to parse json")
            tokenResponseDelegate.onAuthorizationFailure(error: .authorizationFailure("Failed to parse server response - failed to parse json"))
            return
        }

    }

    public func createAuthenticationHeader(clientId:String) throws -> String {
        let signed = try SecurityUtils.signString(clientId, keyIds: (AppIDConstants.publicKeyIdentifier, AppIDConstants.privateKeyIdentifier), keySize: 512)
        return AppIDConstants.BASIC_AUTHORIZATION_STRING + " " + (clientId + ":" + signed).data(using: .utf8)!.base64EncodedString()
    }

    public func clearStoredToken() {
        self.latestAccessToken = nil
        self.latestIdentityToken = nil
        self.latestRefreshToken = nil
    }

}
