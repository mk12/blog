---
title: "Chasing the infinite"
description: "Surprising mathematical results on infinity"
categories: ["math"]
date: "2015-05-10T21:45:00-04:00"
---

What is infinity? Perhaps, like me, you were told that it's just a _concept_ to remind us that there is no largest number. It's true that if you treat it like a regular number, subject to the usual rules of arithmetic, you run into all kinds of confusing nonsense. But this needn't prevent us from studying the properties of infinity---it just means we need to be careful. The infinite is far more interesting and surprising than I could have imagined.

<!--more-->

# Cardinality and bijections

In order to understand infinity, we need to make a detour to set theory. A _set_ is a collection of objects, and the _cardinality_ of a set is the number of unique objects it contains. For example, the set \\(S=\\{\bigcirc,\square,\bigtriangleup\\}\\) has cardinality \\(\lvert S \rvert = 3\\). Two sets have the same cardinality if and only if their objects can be paired off without leaving any out. This pairing-off is a called a _bijection_ or a _one-to-one correspondence_, technically defined as a function that is both injective and surjective.[^1] For example, given the set \\(B=\\{2,3,5\\}\\), we can prove that \\(\lvert S \rvert = \lvert B \rvert\\) by constructing a bijection &thinsp;\\(f\colon S\to B\\) that maps \\(\bigcirc\\) to 2, \\(\square\\) to 3, and \\(\bigtriangleup\\) to 5.

Of course it's obvious that both sets contain three objects, but the power of this method is that it allows us to compare infinite sets. Given that infinity plus one is still infinity, can we conclude that all infinities are the same? Common sense says yes: how can anything possibly be _bigger_ than infinity? However, as is often the case in mathematics, we really need to throw common sense out the window if we want to discover the truth.

# Hilbert's hotel

Suppose you're trying to book a room in an infinite hotel. The innkeeper informs you that all rooms are taken. Disappointed, you turn away to leave.

"Wait!" shouts the innkeeper, "I can make room for you." He knocks on the door of Room 1, and politely asks the guest to move to Room 2. That room also being occupied, he persuades the guest of Room 2 to move to Room 3. And so it continues, each guest moving to an adjacent room. The innkeeper then hands you the key to the first room.

Soon afterwards, an infinite number of people arrive and cram in the hotel reception. They, too, are unhappy to discover that all rooms are occupied.

"It's okay," the innkeeper assures the party. "Just make sure you take odd-numbered rooms." He then rushes ahead and knocks on your door, telling you to move to the second room. The guest in Room 2 is told to move to Room 4, and the guest in Room 3, to Room 6. Each guests goes to the room whose number is double their own, and in this way an infinite amount of odd-numbered rooms become free for the new guests.

# Countability

Hilbert's hotel illustrates that adding one to a regular infinity, or even multiplying it by two, leaves you with the same infinity. This value is the cardinality of the natural numbers \\(\mathbb{N}=\\{0,1,2,\dots\\}\\), and we denote it by \\(\lvert\mathbb{N}\rvert=\aleph\_0\\) (pronounced _aleph nought_). If a set's cardinality is equal to \\(\aleph\_0\\), then we call it a _countable infinity_, because it's possible to count off all its objects by association with natural numbers. Roughly speaking, if you can generate a list of all objects in a set by following some pattern, then the set is countably infinite. All other infinities are larger, and called _uncountable_.

Another way of interpreting the hotel example is this: _there are just as many even numbers as natural numbers_. In a way this seems wrong---surely there are _twice_ as many natural numbers? But both sets are countably infinite, so their cardinalities must be the same: we prove this by constructing the bijection &thinsp;\\(f(n)=2n\\). You might argue that this is just a matter of definition, and that it is meaningless to say that two infinities are equal. Perhaps, but that is a philosophical question, not a mathematical one. Whether you subscribe to the formalist "useful but meaningless marks on paper" or the Platonist "objective, timeless truths about abstract entities" is completely up to you. Rest assured: there are good reasons for using the bijection-based definition, and there is still more we can learn from it.

For example, the integers are countably infinite as well: we can construct the bijection &thinsp;\\(f\colon\mathbb{N}\to\mathbb{Z}\\) that lists the integers by alternating signs:

\\[0,+1,-1,+2,-2,+3,-3,\dots\\]

More surprising is the fact that the rationals are countable: \\(\lvert\mathbb{Q}\rvert=\aleph\_0\\). How can this be, when there are infinitely many rationals between 0 and 1? There are many ways of proving this, but I'm more interested in giving you an intuitive understanding of countability. We can take care of signs using the alternating trick, but what then? We can't go in increasing order, since the rationals get arbitrarily close to zero. And \\(\frac11,\frac12,\frac13,\dots\\) is a dead end, because we'll never get past one! But look at this:

{{< img src="fraction-table.svg" cap="Counting the rationals by zigzagging through a matrix" >}}

We can generate a list of all rationals just by following the red arrows, as long as we include zero somewhere and put \\(\pm\\) in each cell. We have to skip some cells to make it a bijection, but that's not a problem. In fact, if we don't skip any cells, the function is surjective and not injective, which tells us that \\(\mathbb{Q}\\) is either countably infinite or finite---and it clearly isn't finite.

# Cantor's diagonal argument

What about the real numbers: is \\(\mathbb{R}\\) countably infinite? Suppose, for the sake of argument, that it is---suppose we can map each natural number to a unique real number without missing any real numbers. This would give us a list of values that might look like this:

\\[x_0=0.7812272323372748\dots\\\\x_1=25.823506400277566\dots\\\\x_2=7.4937386056237065\dots\\\\x_3=3.1415926535897932\dots\\\\\qquad\vdots\quad\vdots\quad\vdots\quad\vdots\quad\vdots\quad\ddots\\]

These are decimal expansions of real numbers; the digits go on forever. We're assuming this is a bijection, so each real number must be unique.[^2] We can represent the digits in our hypothetical list with variables:

\\[x\_0=\,?\,.\boxed{d\_{11}}d\_{12}d\_{13}d\_{14}\dots\\\\x\_1=\,?\,.d\_{21}\boxed{d\_{22}}d\_{23}d\_{24}\dots\\\\x\_2=\,?\,.d\_{31}d\_{32}\boxed{d\_{33}}d\_{34}\dots\\\\x\_3=\,?\,.d\_{41}d\_{42}d\_{43}\boxed{d\_{44}}\dots\\\\\qquad\vdots\quad\vdots\quad\vdots\quad\vdots\quad\ddots\\]

I've put question marks before the decimal points because I only care about the fractional part. Now, this list is supposed to be complete---every real number needs to be on it somewhere. But consider the real number \\(y=0.e\_1e\_2e\_3e\_4\dots\\), where \\(e\_1\ne d\_{11}\\), \\(e\_2\ne d\_{22}\\), \\(e\_3\ne d\_{33}\\), and so on. This still leaves us with eight symbols to choose from for each digit of \\(y\\). Since the first digits differ, \\(y\ne x\_0\\). Similarly, \\(y\ne x\_1\\), because the second digits differ. Generalizing this to all the \\(x\\) values, we realize that \\(y\\) is not on the list. But \\(y\\) is a real number! This is a contradiction, therefore our initial assumption was wrong: it is impossible to construct this list. In reality, \\(\lvert\mathbb{R}\rvert\ne\aleph\_0\\), so the set of real numbers is uncountably infinite.

The _continuum hypothesis_ states that \\(\lvert\mathbb{R}\rvert=\aleph\_1\\), which means that there is no intermediate infinity between the cardinalities of the naturals and the reals. This has never been proven or disproven. In fact, it's impossible to do either in ZFC,[^3] the standard axiomatic set theory used today. You can assume that it's true or that it's false, and the theory remains consistent, assuming ZFC is consistent in the first place (also unprovable). There is no consensus on what all this actually means. Does the question become meaningless just because it can't be decided by our current axiomatic framework? We are once again getting into philosophical territory.

# Higher dimensions

Yet another counterintuitive fact about cardinalities is that \\(\lvert\mathbb{R}\rvert=\lvert\mathbb{R}^2\rvert\\). In other words, there are just as many points on the real number line as there are on the Cartesian plane. This is true even even though we can divide the plane into infinitely many lines. Consider a point \\((x,y)\\) on the plane, where

\\begin{alignat}{3}x &= \dots~& a\_3a\_2a\_1&.d\_1d\_2d\_3&~\dots\\\\
y &= \dots~& b\_3b\_2b\_1&.e\_1e\_2e\_3&~\dots\\end{alignat}
We can construct a bijection[^4] &thinsp;\\(f\colon\mathbb{R}^2\to\mathbb{R}\\) by interleaving the digits:

\\[f(x,y)=\dots a\_3b\_3a\_2b\_2a\_1b\_1.d\_1e\_1d\_2e\_2d\_3e\_3\dots\\]

This idea generalizes: for any infinite set \\(X\\) and finite natural number \\(n\\), we have \\(\lvert X\rvert=\lvert X^n\rvert\\). Before this was discovered, the number of coordinates required to represent a point in a space was assumed to be an invariant of that space. This is not true, since a single real number can be used to represent a point in a space of any dimension, and vice versa.

# Cardinals and ordinals

So far, we've only talked about infinite values that are cardinalities of infinite sets. These values are the _cardinal numbers_:

\\[0,1,2,\dots,n,\dots,\aleph\_0,\aleph\_1,\aleph\_2,\dots,\aleph\_\alpha,\dots\\]

Every natural number is finite. The first infinite cardinal is \\(\aleph\_0\\), and we call it countably infinite. Everything past \\(\aleph\_0\\) is uncountably infinite. The aleph numbers are strange because adding one to them, or even doubling them, results in the same cardinal. However, if we take the power set[^5] of \\(\mathbb{N}\\), we get a set with cardinality \\(2^{\aleph\_0}=\lvert\mathbb{R}\rvert>\aleph\_0\\). If the continuum hypothesis is true, then \\(\aleph\_1=2^{\aleph\_0}\\). In any case, we can generate ever-larger uncountable infinities with this kind of exponentiation.

The _ordinal numbers_ are another way of extending the natural numbers to infinity. The definition is a bit more complex: two well-ordered sets represent the same ordinal if and only if they are order isomorphic, meaning there exists an order-preserving bijection between them. As a result, ordinals can discriminate infinities more finely than cardinals:

\\[0,1,\dots,n,\dots,\omega,\omega+1,\dots,\omega\\!\cdot\\!2,\omega\\!\cdot\\!3,\dots,\omega^2,\omega^3,\dots,\omega^\omega,\omega^{\omega^\omega},\dots,\epsilon\_0\\]

As with cardinals, the finite ordinals are simply natural numbers. The least infinite ordinal is \\(\omega\\), and it is equivalent to \\(\aleph\_0\\). Unlike the cardinals, \\(\omega+1\\) is distinct from \\(\omega\\), though both are countable. Strange as it may seem, there are uncountably many countably infinite ordinal numbers. We can add to \\(\omega\\), multiply it, square it, raise it to the power \\(\omega\\), ... each of these is a countable infinity greater than the last. The next step is to repeat the exponentiation using the recursive definition \\(\epsilon\_0=\omega^{\epsilon\_0}\\).

{{< img src="ordinal-spiral.svg" cap="Spiral visualization of some countable ordinal numbers (Wikimedia Commons)" >}}

We can play this game as long as we want, but no matter what system we come up with, it will never capture all the infinities---there will always be a larger ordinal that lies outside the system. We can keep finding these larger ordinals, but they become more and more difficult to describe. And we're still only talking about countable ordinals! The first _uncountable_ ordinal is \\(\omega\_1\\), and it is represented by the set of all countable ordinals.

# Conclusion

We often use the symbol \\(\infty\\) without thinking twice, but infinity is so much more strange and intricate than the simple idea of numbers never ending. Our human intuition is a poor guide here, as is demonstrated by nearly every result on the subject. Incidentally, it's thanks to Georg Cantor, the inventor of set theory, that we know about (almost) everything I've written here. Cantor encountered fierce objection to his work precisely because it was so counterintuitive, but today we recognize it as a cornerstone of modern number theory. That being said, number theory is far from being a complete story! And there's much more to be said about infinity than I've been able to fit in this finite article---I was tempted to make it infinitely long, but I've gone on for long enough now.

[^1]: Injections and surjections are special classes of functions. An injective function (_one-to-one_ function) preserves distinctness: no two inputs are mapped to the same output. A surjective function (_onto_ function) is required to map to every output value in its codomain at least once.

[^2]: We have to watch out for values with infinite repeating nines. Although 0.999… and 1.0 look different, they in fact represent the same real number. We get around this by picking one representation and using it consistently in the list.

[^3]: ZFC is short for "Zermelo--Fraenkel set theory with the axiom of choice."

[^4]: Once again, there are some complications with repeating decimals. There are other, more complicated ways of constructing the desired bijection.

[^5]: The power set of a set \\(S\\), denoted by \\(\mathcal{P}(S)\\), is the set of all subsets of \\(S\\), including the null set and \\(S\\) itself.
