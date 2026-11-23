import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@main struct Main {
 static func main() {
  guard CommandLine.arguments.count == 2 else { fatalError("port") }
  let host = "http://127.0.0.1:\(CommandLine.arguments[1])/"
  assert(RuntimeServerSettings.save(loginAddress: "202.189.23.85:22973", resourceAddress: host) == nil)
  let base = FileManager.default.temporaryDirectory
  let hot = ResourceHotUpdater(gameRoot: base, revision: "2026111703")!
  let done = DispatchSemaphore(value: 0)
  var success = false
  hot.fetch("resource/test.swf") { result in
   if case .success(let file) = result, let data = try? Data(contentsOf: file), data.prefix(3) == Data("FWS".utf8) { success = true }
   done.signal()
  }
  assert(done.wait(timeout: .now() + 8) == .success)
  assert(success)
  assert(hot.cachedFile("resource/test.swf") != nil)
  let fail = DispatchSemaphore(value: 0)
  var rejected = false
  hot.fetch("resource/bad.swf") { result in
   if case .failure = result { rejected = true }; fail.signal()
  }
  assert(fail.wait(timeout: .now() + 8) == .success)
  assert(rejected)
  try? ResourceHotUpdater.clearAllCachedResources()
  UserDefaults.standard.removeObject(forKey: RuntimeServerSettings.resourceKey)
  print("Local HTTP fallback / SWF integrity / cache: PASS")
 }
}
