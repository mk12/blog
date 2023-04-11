- drafts
- fix heading levels https://marked.js.org/using_pro#walk-tokens
- templates inherit context (and make if/ranges more consistent with nested templates)
- the /index.html pointless, e.g. /blog/post/ray-tracer/index.html, is pointless if we are aiming to make it work locally, because then the links must include the /index.html
    - either give up filesystem, always use server; then can omit /index.html for pretty URLs
    - or double down on filesystem, and just do post-name.html
+ make public/index.html twice after clean seems to rebuild it
    + Just forgot the pipe to make .d dir order-only
x in .d, order-only on css, img?
    x doesn't make sense for img, will miss it on the first time
+ remove `<!-- more -->`
+ index page
+ categories page
+ archive page
+ prev/next links
+ en/em dashes
