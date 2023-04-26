- update README
- dark mode (including SVGs)
- consider MathML instead of KaTeX
- in index.xml, render links to other article in summaries with full URL
- broken link http://lindenmayer.mitchellkember.com/koch/4
- fix heading levels https://marked.js.org/using_pro#walk-tokens
- server that uses websocket so that it can force refresh after watch + make
+ drafts
+ link between posts, use .md filesystem path
+ ugly duplicate math in lindenmayer
x the /index.html pointless, e.g. /blog/post/ray-tracer/index.html, is pointless if we are aiming to make it work locally, because then the links must include the /index.html
    x either give up filesystem, always use server; then can omit /index.html for pretty URLs
    x or double down on filesystem, and just do post-name.html
+ templates inherit context (and make if/ranges more consistent with nested templates)
+ make public/index.html twice after clean seems to rebuild it
    + Just forgot the pipe to make .d dir order-only
+ in .d, order-only on css, img?
    + doesn't make sense for img, will miss it on the first time
    + actually decided to do it
+ remove `<!-- more -->`
+ index page
+ categories page
+ archive page
+ prev/next links
+ en/em dashes
