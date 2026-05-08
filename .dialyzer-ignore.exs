# .dialyzer-ignore.exs
#
# `safe_close/1` in `stream_session/impl.ex` defensively handles a non-`:ok`
# return from `Mint.HTTP.close/1`. Mint's typespec only declares `:ok`,
# so Dialyzer flags the fallback clause as unreachable. The fallback
# exists because Mint can in fact return `{:error, _}` or raise when the
# underlying socket is already torn down at the kernel level — see the
# inline comment at the call site for the rationale. The clause is kept
# deliberately even though Dialyzer does not see how it's reached.
[
  {"lib/sorrel/stream_session/impl.ex", :pattern_match_cov}
]
