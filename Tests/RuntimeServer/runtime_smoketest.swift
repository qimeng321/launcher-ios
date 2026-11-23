import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@main struct Smoke {
 static func main() {
   assert(RuntimeServerSettings.parseLogin("202.189.23.85:22973")?.host == "202.189.23.85")
   assert(RuntimeServerSettings.parseLogin("999.1.1.1:22973") == nil)
   assert(RuntimeServerSettings.parseLogin("202.189.23.85:0") == nil)
   assert(RuntimeServerSettings.parseLogin("example.com:22973") == nil)
   assert(RuntimeServerSettings.parseLogin("202.189.23.85:22973/evil") == nil)
   assert(RuntimeServerSettings.validateResourceURL("https://example.com/root")?.absoluteString == "https://example.com/root/")
   assert(RuntimeServerSettings.validateResourceURL("http://202.189.23.85:29380/") != nil)
   assert(RuntimeServerSettings.validateResourceURL("https://example.com/root/../a") == nil)
   assert(RuntimeServerSettings.validateResourceURL("file:///etc/passwd") == nil)
   assert(RuntimeServerSettings.validateResourceURL("http://example.com/a?x=1") == nil)
   assert(ResourceHotUpdater.isAllowedResource("resource/foo/bar.swf"))
   assert(!ResourceHotUpdater.isAllowedResource("../foo.swf"))
   assert(!ResourceHotUpdater.isAllowedResource("resource/%2E%2E/evil.swf"))
   assert(!ResourceHotUpdater.isAllowedResource("/etc/passwd"))
   assert(RuntimeServerSettings.save(loginAddress: "202.189.23.85:22973", resourceAddress: "") == nil)
   assert(RuntimeServerSettings.resourceBaseURL == nil)
   assert(RuntimeServerSettings.save(loginAddress: "bad", resourceAddress: "") != nil)
   assert(RuntimeServerSettings.login.host == "202.189.23.85")
   print("Runtime settings and resource path assertions: PASS")
 }
}
