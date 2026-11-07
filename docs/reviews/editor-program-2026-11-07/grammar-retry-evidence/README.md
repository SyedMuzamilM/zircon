# Bounded grammar retries

The pre-fix portable run reproduced four failures: same-revision transient failures never retried, malformed response lengths escaped as InvalidHighlights, and persistent failure never progressed past the first attempt. The earlier test compilation error was corrected before capturing this red run.

The final six journeys cover transient process failure, invalid response length, invalid spans, preserving an unrelated error on successful retry, ignoring an older source revision failure, and exhausting three attempts before an edit rearms the budget. Retries wait 250 ms then 500 ms on the application clock. Installed revision advances only after publishing valid highlights. Language rebind and service restart reset the budget.

`portable.txt`: 73 passed, 4 explicit native-only skips, 77 total. `native.txt`: 102/102 passed through the sequential AppKit/renderer/editor/settings/rendering chain, including all six retry journeys and existing language-epoch cases. No foreground skip occurred in this run. `release.txt`: release install and benchmark driver built, 73 application checks passed with four native-only skips. These runs overlap tests and must not be summed as unique coverage. No latency improvement is claimed.

Full persistent grammar workers, interruptible stdin writes and asynchronous language-client shutdown remain open. This fix bounds retries after returned failures; it does not make a hung process immediately cancelable.
