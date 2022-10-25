# Blog

This is the source for my personal blog. It uses [Hugo].

I host it at https://mitchellkember.com/blog.

## Usage

Run `make serve` to serve and live reload the blog. This requires a creating a `fonts` directory or symlink in the repository root containing the WOFF2 fonts.

Run `make DESTDIR=/path/to/website FONT_URL=/path/to/fonts` to build the blog. `DESTDIR` is a fileystem path with `FONT_URL` is a relative URL where WOFF2 fonts are found in the final website. This assumes the blog is embedded in a larger website.

## Fonts

This blog uses the fonts Equity, Concourse, and Triplicate. You can buy them at https://mbtype.com.

[Hugo]: https://gohugo.io
