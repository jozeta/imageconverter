/// Joins byte arrays. Long `a + b + c + …` chains of `[UInt8]` with literals make older Swift compilers (Xcode 16,
/// used by CI) give up type-checking; one variadic call is checked in linear time.
func concat(_ parts: [UInt8]...) -> [UInt8] { parts.flatMap { $0 } }
