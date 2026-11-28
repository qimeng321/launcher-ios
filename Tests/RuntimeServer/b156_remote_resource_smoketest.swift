import Foundation
@main struct B156RemoteResourceSmokeTest {
 static func main() {
  let base=RuntimeServerSettings.validateResourceURL("http://103.236.79.37:32400")
  precondition(base?.absoluteString=="http://103.236.79.37:32400/")
  precondition(RuntimeServerSettings.validateResourceURL("file:///etc/passwd")==nil)
  precondition(RuntimeServerSettings.validateResourceURL("http://user:pass@example.test/")==nil)
  precondition(RuntimeServerSettings.validateResourceURL("http://example.test/a/../b")==nil)
  precondition(RuntimeServerSettings.isAllowedRemoteResourcePath("config/doorConfig.xml"))
  precondition(RuntimeServerSettings.isAllowedRemoteResourcePath("dll/SailCore.swf"))
  precondition(!RuntimeServerSettings.isAllowedRemoteResourcePath("../etc/passwd"))
  precondition(!RuntimeServerSettings.isAllowedRemoteResourcePath("config/%252e%252e/secret.xml"))
  let url=RuntimeServerSettings.remoteResourceURL(base:base!,relativePath:"config/doorConfig.xml",query:"v=1")
  precondition(url?.absoluteString=="http://103.236.79.37:32400/config/doorConfig.xml?v=1")
  let xml=#"<Email ip="1.1.1.1" port="1000"/><Other ip="9.9.9.9" port="9"/>"#
  let rewritten=RuntimeServerSettings.rewriteServerEndpointXML(xml,endpoint:LoginEndpoint(host:"103.236.79.37",port:1863))
  precondition(rewritten.contains(#"<Email ip="103.236.79.37" port="1863"/>"#))
  precondition(rewritten.contains(#"<Other ip="9.9.9.9" port="9"/>"#))
  print("PASS B156 resource URL/path/XML smoke test")
 }
}
