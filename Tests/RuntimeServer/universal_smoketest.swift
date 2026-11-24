import Foundation
@main struct UniversalSmoke {
    static func main() {
        let endpoint = RuntimeServerSettings.parseLogin("192.0.2.10:1863")!
        assert(RuntimeServerSettings.parseLogin("192.0.2.10:0") == nil)
        let xml = "<root><Email ip=\"198.51.100.1\" port=\"22973\"/><DirSer port='5000' ip='198.51.100.2'/><Other ip=\"198.51.100.3\" port=\"80\"/></root>"
        let output = RuntimeServerSettings.rewriteLoginXML(xml, endpoint: endpoint)
        assert(output.contains("<Email ip=\"192.0.2.10\" port=\"1863\"/>"))
        assert(output.contains("<DirSer port='1863' ip='192.0.2.10'/>"))
        assert(output.contains("<Other ip=\"198.51.100.3\" port=\"80\"/>"))
        assert(RuntimeServerSettings.resourceBaseURL == nil)
        print("Universal endpoint rewrite and local-only assertions: PASS")
    }
}
