// Looks up the Oxford Spanish-English dictionary that macOS already has installed.
// No network and no API: it talks to DictionaryServices (CoreServices) directly, the
// same data you see in Dictionary.app. The DCS* symbols are not in the public headers,
// so they are loaded with dlsym.
import Foundation

typealias AvailFn = @convention(c) () -> Unmanaged<CFSet>?
typealias NameFn = @convention(c) (AnyObject) -> Unmanaged<CFString>?
typealias DefFn = @convention(c) (AnyObject?, CFString, CFRange) -> Unmanaged<CFString>?

let raw = CommandLine.arguments.dropFirst().joined(separator: " ")
let word = raw
    .trimmingCharacters(in: .whitespacesAndNewlines)
    .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
guard !word.isEmpty else { exit(1) }

let handle = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW)
guard let pAvail = dlsym(handle, "DCSCopyAvailableDictionaries"),
      let pName = dlsym(handle, "DCSDictionaryGetName"),
      let pDef = dlsym(handle, "DCSCopyTextDefinition") else { exit(1) }
let available = unsafeBitCast(pAvail, to: AvailFn.self)
let nameOf = unsafeBitCast(pName, to: NameFn.self)
let define = unsafeBitCast(pDef, to: DefFn.self)

// Find the bilingual one; if it is missing, fall back to the default dictionary (English).
var target: AnyObject? = nil
if let set = available()?.takeRetainedValue() as? Set<AnyHashable> {
    for item in set {
        let obj = item as AnyObject
        let name = nameOf(obj)?.takeUnretainedValue() as String? ?? ""
        if name.contains("Español") && name.contains("Inglés") { target = obj; break }
    }
}

func lookup(_ dict: AnyObject?) -> String? {
    define(dict, word as CFString, CFRangeMake(0, word.count))?.takeRetainedValue() as String?
}

guard var text = lookup(target) ?? lookup(nil) else { exit(1) }

// Remove the phonetics "| AmE ..., BrE ... |" and the trailing phrases: in a small
// bubble they only get in the way.
if let r = text.range(of: #"\s\|[^|]{0,120}\|\s"#, options: .regularExpression) {
    text.replaceSubrange(r, with: " ")
}
for cut in ["PHRASAL VERBS", "IDIOMS"] {
    if let r = text.range(of: cut) { text = String(text[..<r.lowerBound]) }
}
print(text.trimmingCharacters(in: .whitespacesAndNewlines))
