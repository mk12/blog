- update README
- redesign, retro
- add favicon
- consider fallible Markdown tokenizer for stricter checks
- figure out FONT_URL
    - probably removing webfonts in the redesign
    - but for now, FONT_URL seems unused? Now that css uses /fonts/
- try bun watch instead of watchexec
+ full dark mode (SVG palettes, including in RSS)
    x not going to use `<style>` in SVG, doesn't work in NetNewsWire
    + just going to stick with currentColor, and #888 can be fine light/dark
    + in the end used #999 for mid-gray, and #b0b0b040 for faded background
+ broken link http://lindenmayer.mitchellkember.com/koch/4
x lindenmayer heroku
+ code block in narrow mode should still have background
+ serve.ts: when doing git operations, avoid so many rebuilds
    + don't need to debounce
    + just need to avoid queuing up changes
    + I have --on-busy-update=do-nothing but that's only for new events during the cat, not during the other command which serve.ts runs
x reconsider `<section>` tags in categories
x consider not quoting attributes
x consistent way of inserting edits/later comments in posts
+ footnote popovers
x render footnotes as sidenotes (?)
+ first year OCD note
x remove analytics
    x useful to see there and in notes4u
x use `<time>` tag
    x pubdate isn't part of HTML5 anymore
x use current time instead of "Draft"
+ upload new website
+ run vnu? (I run it in mitchellkember.com repo)
x consider var for single character math element
    x too hard to match font
+ complete RSS feed
    + make SVGs visible in dark mode
    - avoid relying on CSS e.g. fonts
+ remove TypeScript implementation
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
