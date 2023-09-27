---
title: Fractal dimensions
subtitle: Exploring the gap between topological dimensions
category: Math
date: 2016-02-07T21:25:00-08:00
---

Most of us are comfortable with the usual notion of <i>dimension</i>. We live in three-dimensional space, and we can easily picture one-dimensional lines and two-dimensional planes. Higher-dimensional spaces are much harder to visualize, but the generalization at least makes sense. Now what could it possibly mean to say that a space has 1.26186 dimensions?

One valid answer would be, "Nothing." Just because you can write it down doesn't mean it is meaningful. It would make just as much sense to talk about _green_ dimensions, as far as the mathematical definitions are concerned. It may be exciting to imagine a mysterious world between the familiar dimensions, but you could argue that whatever 1.26186 belongs to is a separate definition, even if we want to use the word <i>dimension</i>.

To this imaginary, skeptical, pedantic reader, I grant all this. I am being a bit disingenuous when I talk about fractional dimensions, because they refer to a different property. There is no 2.5th dimension, in the sense that a vector cannot have 2.5 components. That being said, these fractional dimensions I want to talk about -- _fractal_ dimensions, actually -- are closely related to the ordinary concept of dimensions. They arise when we try to assign a topological dimension to fractal curves.

First, I should clarify what I mean by _topological_ dimension. We commonly consider circles and polygons as belonging to the flat, two-dimensional world, while spheres and polyhedrons exist in three dimensions. This, although not exactly wrong, is imprecise. A circle is a one-dimensional curve, and a sphere is a two-dimensional closed surface. Both can be _embedded_ in the Euclidean space one dimension higher. But we can also consider them as spaces in themselves. If you were trapped on a sphere, your experience would be two-dimensional, not three-dimensional. There are rigorous ways to define this quantity, but I won't go into them here.

Now we come to the fractal part. Consider the Koch snowflake, a fractal curve that I wrote about in my article on [Lindenmayer systems][linden]:

![First three generations of the Koch snowflake](../assets/svg/koch.svg)

Of course, none of those three figures is a Koch snowflake. The real snowflake is obtained by taking the process to infinity, adding more and more spikes, and in so doing, enclosing a finite area with an infinite perimeter. You can use the [Lindenmayer web app][koch4] to get a better idea of this -- after a while, the changes between generations become too small to notice. Now we ask the question: what is the topological dimension of the Koch snowflake?

At first, the answer seems to be obvious: "One." It's a strange curve, but it's still just a curve, and in theory we might be able to smooth out its jaggedness and get an infinitely large circle. But, for that matter, how do we know a circle is one-dimensional? These questions force us to come up with better definitions.

Here's an idea: we know circles and polygons are one-dimensional because if we _zoom in_ far enough on any part, we see a straight line. Similarly, if you get close enough to a sphere, the surface becomes nearly flat. This technique lets us distinguish one-dimensional scribbles from authentic two-dimensional filled quadrilaterals. But we immediately run into trouble when we try to apply it to fractals like the Koch snowflake: we can never finish zooming in! How can we really be sure that every part is a straight line segment when it's impossible to look close enough to verify?

We know for sure the dimension can't be more than 2, because we can clearly embed the snowflake in $\mathbb{R}^2$. Hopefully you'll agree that it also can't be less than 1. Now where does that leave us? I'll jump straight to the answer: the fractal dimension of the Koch snowflake is between 1 and 2:

$$\frac{\log 4}{\log 3}\approx 1.26186.$$

It twists and turns a bit too much to be one-dimensional, but not enough to be two-dimensional. It's not always possible to calculate fractal dimension values exactly, but in the case of the Koch snowflake we can. In other cases, the best we have are empirically determined values. The calculation of 1.26186 involves counting self-replicated parts and their scale factors.

You might not be entirely convinced. Why should an excessively jagged snowflake be any different from other polygons? Let's consider another fractal curve, the Hilbert curve:

![First three generations of the Hilbert curve](../assets/svg/hilbert.svg)

This is a space-filling curve: when we take the process to infinity, it becomes equivalent to the unit square. It should come as no surprise, then, that its fractal dimension is 2. It twists around in such a convoluted way that it covers every single point in the unit square. This is one of the things that make fractal dimensions interesting: at a basic level, they allow us to quantify how convoluted a fractal curve is.

Fractal dimensions are a great example of how mathematics develops when strange discoveries challenge long-held intuitions. Consider non-Euclidean geometry: an entire world that remained undiscovered until someone tried swapping out Euclid's parallel postulate for something far stranger. And mathematics has no shortage of strangeness -- I invite you to look up the pathological Weierstrass function and the Monster group (also known as the Friendly Giant). Finally, if your curiosity about dimensions hasn't been satisfied, I highly recommend [<cite>Flatland: A Romance of Many Dimensions</cite>][flatland].

[linden]: lindenmayer.md
[koch4]: https://lindenmayer.mitchellkember.com/koch/4
[flatland]: https://www.gutenberg.org/ebooks/201
