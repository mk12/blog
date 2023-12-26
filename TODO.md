- update README
- redesign, retro
- code block in narrow mode should still have background
- consistent way of inserting edits/later comments in posts
- first year OCD note
- render footnotes as sidenotes (?)
- dark mode (including SVGs)
- broken link http://lindenmayer.mitchellkember.com/koch/4
- lindenmayer heroku
- consider fallible Markdown tokenizer for stricter checks
- consider var for single character math element
- remove TypeScript implementation
- run vnu? (I run it in mitchellkember.com repo)
- reconsider `<section>` tags in categories
- upload new website
- consider not quoting attributes
- figure out FONT_URL
    - probably removing webfonts in the redesign
    - but for now, FONT_URL seems unused? Now that css uses /fonts/
+ complete RSS feed
    + make SVGs visible in dark mode
    - avoid relying on CSS e.g. fonts
+ avoid showing build status page, loses scroll position
+ in index.xml, render links to other article in summaries with full URL
+ math: more UTF-8 (e.g. `\ne`)
+ generate.zig url generation stuff
    + full https://... links in XML
+ replace std.fmt.format(writer, ...) with writer.print(...)
+ server that uses websocket so that it can force refresh
+ comma after math wraps (e.g. "We can add to $\omega$, "For all $a$ and $b$")
x UTF-8 mathvariants seem to have weird spacing :/
x replace " " with `&nbsp;`?
+ smart quotes in parens broken
+ consider MathML instead of KaTeX
+ Zig changes to scanner
    x non fallable. user of scanner reports errors. Scanner's job is mainly keeping track of line/col
        x no, it actually is useful for it to help with errors too
        x and storing in buffer is simpler than parameterizing on the writer
    x based on reader, not assuming bytes
        x no, that's not the model I need
    + be able to get position to use in error, or return it with token like Go scanner
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
