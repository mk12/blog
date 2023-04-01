package main

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"github.com/alecthomas/chroma"
	"github.com/alecthomas/chroma/lexers"
	"github.com/rjeczalik/notify"
)

func printUsage(w io.Writer) {
	fmt.Fprintf(w,
		`Usage: %s SOCKET [FIFO]

Runs a server that highlights code using https://github.com/alecthomas/chroma

Arguments:
    SOCKET  Socket path. The server creates a stream-oriented Unix domain socket
            here to listen on. It exits automatically if SOCKET is removed.
    FIFO    Synchronization file. If provided, the sever signals FIFO (opens it
            for writing and closes it) when ready to serve requests on SOCKET.

Request format:
    LANGUAGE ":" CODE "\0"

Response format:
    (HTML_OUTPUT | "error:" ERROR_MESSAGE) "\0"
`,
		os.Args[0])
}

func main() {
	log.SetFlags(0)
	log.SetPrefix(os.Args[0] + ": ")
	if len(os.Args) < 2 || os.Args[1] == "-h" || os.Args[1] == "--help" {
		printUsage(os.Stdout)
		return
	}
	if len(os.Args) > 3 {
		printUsage(os.Stderr)
		os.Exit(1)
	}
	socket := os.Args[1]
	var fifo string
	if len(os.Args) == 3 {
		fifo = os.Args[2]
	}
	if err := run(socket, fifo); err != nil {
		log.Fatal(err)
	}
}

// run runs the server on socket, signaling fifo once it is ready.
func run(socket, fifo string) error {
	if _, err := os.Stat(socket); err == nil {
		return fmt.Errorf("%s: socket already exists", socket)
	}
	onSignals(func() { os.Remove(socket) },
		os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	l, err := net.Listen("unix", socket)
	if err != nil {
		return err
	}
	defer l.Close()
	defer os.Remove(socket)
	log.Printf("listening on %s", socket)
	socketRemoved := make(chan notify.EventInfo, 1)
	if err := notify.Watch(socket, socketRemoved, notify.Remove); err != nil {
		return err
	}
	defer notify.Stop(socketRemoved)
	if fifo != "" {
		log.Printf("signaling %s", fifo)
		f, err := os.OpenFile(fifo, os.O_WRONLY, 0)
		if err != nil {
			return err
		}
		f.Close()
	}
	fatalError := make(chan error)
	go func() {
		for {
			conn, err := l.Accept()
			if err != nil {
				fatalError <- err
				return
			}
			go func() {
				defer conn.Close()
				if err := serve(conn); err != nil {
					log.Print(err)
				}
			}()
		}
	}()
	select {
	case <-socketRemoved:
		return nil
	case err := <-fatalError:
		return err
	}
}

// onSignals starts a goroutine that listens for sigs. When one of them arrives,
// it runs f and then re-raises the signal to invoke the default handler.
func onSignals(f func(), sigs ...os.Signal) {
	c := make(chan os.Signal, 1)
	signal.Notify(c, sigs...)
	go func() {
		sig := <-c
		f()
		signal.Stop(c)
		proc, _ := os.FindProcess(os.Getpid())
		proc.Signal(sig)
	}()
}

// serve serves requests on conn.
func serve(conn io.ReadWriter) error {
	scanner := bufio.NewScanner(conn)
	scanner.Split(func(data []byte, atEOF bool) (advance int, token []byte, err error) {
		if atEOF && len(data) > 0 {
			return 0, nil, fmt.Errorf("unexpected EOF before null terminator")
		}
		if i := bytes.IndexByte(data, 0); i >= 0 {
			return i + 1, data[0:i], nil
		}
		return 0, nil, nil
	})
	w := bufio.NewWriter(conn)
	for scanner.Scan() {
		if err := handle(w, scanner.Text()); err != nil {
			fmt.Fprintf(w, "error:%s", err)
		}
		w.WriteByte(0)
		w.Flush()
	}
	return scanner.Err()
}

// handle handles a single request, req, and writes the response to w.
func handle(w io.Writer, req string) error {
	lang, code, ok := strings.Cut(req, ":")
	if !ok {
		return fmt.Errorf("invalid request: no ':' found")
	}
	lexer := lexers.Get(lang)
	if lexer == nil {
		return fmt.Errorf("%q: unsupported language", lang)
	}
	iter, err := lexer.Tokenise(nil, code)
	if err != nil {
		return fmt.Errorf("lexing code: %w", err)
	}
	writeHTML(w, iter, getClassifier(lang))
	return nil
}

// writeHTML reads tokens from iter and writes highlighted HTML to w.
func writeHTML(w io.Writer, iter chroma.Iterator, classify classifier) {
	var class string
	flushClass := func() {
		if class != "" {
			fmt.Fprintf(w, "</span>")
			class = ""
		}
	}
	var space strings.Builder
	flushSpace := func() {
		if space.Len() > 0 {
			fmt.Fprint(w, space.String())
			space.Reset()
		}
	}
	var prev, t, next chroma.Token
	next = iter()
	for next != chroma.EOF {
		prev, t, next = t, next, iter()
		if strings.TrimSpace(t.Value) == "" {
			space.WriteString(t.Value)
			continue
		}
		c := classify(prev, t, next)
		if c != class {
			flushClass()
			flushSpace()
			if c != "" {
				fmt.Fprintf(w, `<span class="%s">`, c)
				class = c
			}
		} else {
			flushSpace()
		}
		value := t.Value
		// log.Print(t)
		value = strings.ReplaceAll(value, "&", "&amp;")
		value = strings.ReplaceAll(value, "<", "&lt;")
		fmt.Fprint(w, value)
	}
	flushClass()
	flushSpace()
}

// A classifier returns the CSS class to use for token t.
type classifier func(prev, t, next chroma.Token) string

// getClassifier returns the classifier to use for a given language.
func getClassifier(lang string) classifier {
	switch lang {
	case "ruby":
		return rubyTokenClass
	default:
		return tokenClass
	}
}

func tokenClass(prev, t, next chroma.Token) string {
	switch t.Type {
	case chroma.KeywordType, chroma.NameBuiltin:
		return "fu"
	case chroma.KeywordPseudo, chroma.NameConstant:
		return "cn"
	}
	if t.Type.InCategory(chroma.Comment) {
		return "at"
	}
	if t.Type.InCategory(chroma.Keyword) {
		return "kw"
	}
	if t.Type.InCategory(chroma.Literal) {
		return "cn"
	}
	return ""
}

func rubyTokenClass(prev, t, next chroma.Token) string {
	switch t.Type {
	case chroma.NameConstant:
		return ""
	case chroma.NameVariableInstance:
		return "fu"
	case chroma.NameBuiltin:
		if t.Value == "test" {
			return "kw"
		}
		return ""
	case chroma.LiteralStringSymbol:
		if next.Value == ":" {
			return ""
		}
	}
	return tokenClass(prev, t, next)
}
