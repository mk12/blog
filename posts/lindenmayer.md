---
title: "Lindenmayer systems"
description: "Using L-systems to draw fractal curves"
categories: ["math"]
date: "2015-09-18T10:28:00-04:00"
---

I've recently become interested in a type of mathematical structure called an L-system. Invented by Aristid Lindenmayer in 1968, an L-system is a grammar that applies recursive rules to produce strings. Lindenmayer originally used them to model biological processes, such as the behaviour of plant cells. They can also be used to draw beautiful fractal curves.

<!--more-->

# What is an L-system?

An L-system has two parts: an _axiom_, and a list of _rules_. The axiom can be any sequence of symbols, like X or 123. Each rule is an instruction to replace a symbol with something else, like "replace X with ABC," or more concisely, X&nbsp;$\to$&nbsp;ABC. There can only be one of these rules for each symbol.

The purpose of the L-system is to generate strings. To do this, we take each of the axiom's symbols, apply the rules to them all in parallel, and combine the results into one string. If there is no rule for a symbol, we leave it as it is. To get the next string, we repeat the same procedure on the new string. This process continues as long as desired, and in most cases the strings keep getting longer and longer.

Consider the L-system whose axiom is A and whose rules are A&nbsp;$\to$&nbsp;ABA and B&nbsp;$\to$&nbsp;BBB. This system is related to the [Cantor set][cs], and it has some interesting properties. Here are its first few generations:

- A
- ABA
- ABABBBABA
- ABABBBABABBBBBBBBBABABBBABA

The string triples in size on each iteration, since both rules replace a single symbol with a string of three. No matter how far we go, the string is always precisely defined by the axiom, the rules, and the number of iterations required to reach it.

# Mathematical structure

In this section I will rigorously define the L-system. This isn't necessary to understand how it works or why it's useful, but it allows us to be far more precise and to avoid the ambiguities of English. It's also necessary if we want to prove anything about L-systems. This is usually done in the wider context of formal language theory, but since I'm not familiar with that, I'm going to do it my own way.

A _symbol_ is any kind of token, such as "A" or "7." A _string_ is a sequence of symbols, denoted by $\langle s_1, \dots, s_n\rangle$. To distinguish variables representing strings, I will set them in boldface. Let $S$ be the set of all symbols and let $\mathbf{S}$ be the set of all strings. Then a string $\mathbf{s}\in\mathbf{S}$ can be formally defined as a function $\mathbf{s}\colon I\to S$ where $I=\{i\in\mathbb{N}:i<N\}$ for some $N$.

We define an L-system as a pair $(\mathbf{a}, P)$ where $\mathbf{a}\in\mathbf{S}$ is the axiom and $P\colon V\to\mathbf{S}$ is the production function. The domain $V\subseteq S$ is the set of _nonterminal_ symbols. All other symbols $t\notin V$ are _terminal_ symbols. We usually define $P$ using a set of the form $\{(v_1,\mathbf{s}_1),\dots,(v_n,\mathbf{s}_n)\}$. From $P$, we construct the function $Q\colon S\to\mathbf{S}$ that extends the domain to $S$ by $Q(t)=\langle t \rangle$ for $t\notin V$. Next, we define the string rewriting function $R\colon\mathbf{S}\to\mathbf{S}$ so that $R(\langle s_1, \dots, s_n\rangle)$ is equal to the concatenation of $Q(s_1),\dots,Q(s_n)$ into a single string. Finally, the L-system generates strings by iteratively applying $R$, so we have $\mathbf{a}$, $R(\mathbf{a})$, $R(R(\mathbf{a}))$, etc. The general string for iteration $n$ can be written $R^{\circ n}(\mathbf{a})$.

# Turtle graphics

Strings might seem uninteresting on their own, but we can interpret them in different ways. In particular, we can interpret symbols as instructions for drawing a picture. The standard way of doing this on a computer is, for historical reasons, called _turtle graphics_. Imagine we have a turtle that leaves a trail of ink as it crawls around. By controlling its movements with the instructions, we draw a picture.

Instead of writing long lists of instructions by hand, we can generate them using an L-system. All we have to do is choose meanings for the symbols. Here is one possibility:

| Symbol | Meaning |
|:------:|:-------:|
| F | move forward by 10 pixels |
| + | rotate counterclockwise by 30º |
| − | rotate clockwise by 30º |
| _other_ | do nothing |

Of course, for this to work, we'd have to create an L-system that includes these three symbols in the strings it generates.

# Fractal curves

L-systems are perfect for drawing fractal curves---shapes that have repeating patterns at every scale. One well-known fractal curve is the Koch snowflake, invented by Helge von Koch in 1904. It begins as an equilateral triangle, and it grows another equilateral triangle on each edge to advance to the next generation. Here are the first few stages:

{{< img src="koch.svg" cap="First three generations of the Koch snowflake" >}}

Technically, the real curve is the result of taking this process to infinity. Once we arrive there, it has an amazing property: its perimeter is infinite, despite enclosing a finite area.

We can draw approximations of the Koch curve using an L-system with the axiom F++F++F and a single rule, F&nbsp;$\to$&nbsp;F--F++F--F. In this case, F means go forward one unit, plus means rotate counterclockwise by 60º, and minus means rotate clockwise by 60º.

# Space-filling curves

A space-filling curve is a special kind of fractal curve that occupies the entire unit square. Constructing one of these is more difficult than you might think. You can't just sweep back and forth, like mowing a lawn, because you would always retrace the same line. Similarly, you can't spiral inwards from the outer edge, because you would always be stuck on the perimeter. The curve must be specified in such a way that taking the limit to infinity will cover the entire unit square.

The Hilbert curve, invented by David Hilbert in 1981, is one of the simplest space-filling curves. It looks like strange, complicated maze, but it can be defined by a relatively simple L-system. Its axiom is A, and its rules are A&nbsp;$\to$&nbsp;+BF--AFA--FB+ and B&nbsp;$\to$&nbsp;--AF+BFB+FA--. We ignore the symbols A and B while drawing, and we make 90º rotations.

{{< img src="hilbert.svg" cap="First three generations of the Hilbert curve" >}}

This curve reveals a remarkable fact: we can specify any point on the unit square with a single real number. Let's define a function $H\colon\mathbb{R}\to\mathbb{R}^2$ where $H(0)$ and $H(1)$ are the coordinates of the start and the end of the curve, respectively. Since it fills the entire square, $H$ will reach each and every point, therefore $\{H(t):t\in[0,1]\}=[0,1]\times [0,1]$. This is an alternative method of proving $\lvert\mathbb{R}\rvert=\lvert\mathbb{R}^2\rvert\$, which I demonstrated by a different method in "[Chasing the Infinite][cti]."

# Fractal plants

Many objects found in nature, including plants, have intricate fractal patterns. L-systems are great for drawing these, but we need a more sophisticated turtle. It must understand two new instructions:

| Symbol | Meaning |
|:------:|:-------:|
| [ | save the current position and orientation |
| ] | restore the last saved position and orientation |

These new symbols allow us to create branches by returning the pen to a previous location and going in a different direction. The result is no longer a curve in the technical sense, but it's still a fractal. Now, let's construct a fractal plant. The axiom is A, and the rules are A&nbsp;$\to$&nbsp;F+[[A]--A]--F[--FA]+A and F&nbsp;$\to$&nbsp;FF. Can you see the self-similarity in the branches?

{{< img src="plant.svg" cap="Fourth generation of the fractal plant" >}}

# Conclusion

The L-system is a wonderful tool for building complexity and infinite detail from a small---and more importantly, finite!---amount of data. I learned about this method while writing a recursive program to draw Hilbert curves. When I rewrote it to use an L-system, the code became much simpler, and I soon realized that it was easily generalizable to dozens of other curves. The final product of this project is a web app called [Lindenmayer][lin]. It currently renders 11 different fractal curves, and you can easily change the number of iterations, stroke thickness, and stroke colour. Please try it out, and give me feedback! The source is available on [GitHub][gh].

[aristid]: https://en.wikipedia.org/wiki/Aristid_Lindenmayer
[cs]: https://en.wikipedia.org/wiki/Cantor_set
[cti]: /blog/post/chasing-the-infinite/#higher-dimensions
[lin]: http://lindenmayer.mitchellkember.com
[gh]: https://github.com/mk12/lindenmayer
