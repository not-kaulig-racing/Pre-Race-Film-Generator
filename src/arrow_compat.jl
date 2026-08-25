using ArrowTypes
using InlineStrings

# Workaround: newer ERDP arrow files (25LOU1+) write short-string columns as
# `Arrow.Primitive{String7, Vector{UInt64}}` — the fixed-width layout where
# each String7 is packed into 8 bytes = one UInt64. Reading a value goes
# through `ArrowTypes.fromarrow(::Type{String7}, ::UInt64)`, whose fallback
# calls `String7(uint64)`. That constructor doesn't exist in InlineStrings, so
# the read blows up with a MethodError.
#
# String7 IS a 64-bit primitive type internally — the arrow writer packs it
# exactly the way `reinterpret(String7, ::UInt64)` unpacks it. Registering
# both entry points here is enough; nothing else has to change.
#
# Older races (25RIC1 and earlier) used variable-length `Arrow.List` encoding
# for the same column, which had its own working read path — this override is
# a pure addition and doesn't affect them.
ArrowTypes.fromarrow(::Type{String7}, x::UInt64) = reinterpret(String7, x)
InlineStrings.String7(x::UInt64) = reinterpret(String7, x)
