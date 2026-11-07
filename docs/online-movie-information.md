# Online movie information

Settings → General → Online Movie Information. Disabled by default. Save a TMDB **API Read Access Token** in Keychain, enable the feature, then open Information → Find Movie Information. Edit the proposed filename-derived title/year if needed. Search checks up to six candidates, retrieves their runtime/details, and sorts by absolute runtime difference in minutes. Duration stays local. Missing runtime sorts last; ties retain provider search order. Confirm a candidate to save; no automatic attribution from filename alone.

First release: local movies, English/Simplified Chinese/Traditional Chinese (Taiwan). No TV episode or remote-URL lookup, poster download, or automatic NFO write. NFO and embedded tags win; online fields fill blanks. No numeric match-confidence claim: alternate cuts, credits and frame-rate conversions can change runtime.

Confirmed records are bounded to 100, keyed by path hash, invalidated by file size/mtime, and stored in app preferences. Disable hides them and stops active searches; Remove Match/Clear Online Matches removes them. Search is explicit, never on playback startup. Requests use HTTPS with Bearer auth, disabled redirects/cookies, bounded detail count, request timeouts and visible auth/rate-limit errors. No raw error-response body or token is logged.

Official docs: https://developer.themoviedb.org/docs/authentication-application ; https://developer.themoviedb.org/reference/search-movie ; https://developer.themoviedb.org/reference/movie-details ; https://developer.themoviedb.org/docs/faq

Validation: build plus offline filename/ranking/precedence checks. Authenticated API and GUI matching require a user-supplied Token; not yet verified here.
