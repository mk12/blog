---
title: The prisoner's dilemma
subtitle: Why people settle for a lose-lose scenario
category: Math
date: 2015-04-17T16:00:00-04:00
---

You've just been thrown in prison. You and another gang member were arrested, and now you are in separate cells with no way of communicating. You both deserve a three-year sentence. However, the police don't have enough evidence to convict you on that charge, so you'll probably end up in jail for one year on a lesser charge instead.

They can't prove it, but the police know what you really did, so they give you an option: testify against the other prisoner, and you'll be set free while he serves three years. But at the same time, they give the option to the other prisoner. What do you do?

# Cooperate or defect?

This is a classic example studied in <dfn>game theory</dfn>. The theory of games is all about competition, conflict, and cooperation between decision makers. Game theorists analyze mathematical models of such situations and consider the strategies that players may adopt. It has applications in psychology, economics, and biology, and it can also help us understand things we experience every day, as we'll see a bit later.

Returning to the dilemma: what would you do? You can either <dfn>cooperate</dfn> by remaining silent, or <dfn>defect</dfn> by betraying the other prisoner. Should you cooperate, and hope he does too? If you both defect, the police cannot set you both free, but they can't completely ignore their promise either, so you would both get two years. There are four possible outcomes:

1. <dfn>Reward:</dfn> you both remain silent (one year in prison).
2. <dfn>Temptation:</dfn> you betray the other prisoner (you're free).
3. <dfn>Sucker's payoff:</dfn> the other prisoner betrays you (three years).
4. <dfn>Punishment:</dfn> you both betray each other (two years).

The outcomes look the same to the other prisoner, except the temptation and sucker's payoff are swapped. It's more clear in a matrix format:

![Payoff matrix of the prisoner's dilemma (your choice on the left)](../assets/svg/prisoner.svg)

What's the best decision to make? Well, the other prisoner will either cooperate or defect. If he cooperates, then you should defect and get off free. If he defects, then you absolutely must defect -- two years is bad, but three is worse! So no matter what the other prisoner does, it's always better for you to defect. The other prisoner independently comes to the same conclusion, so you are both doomed to a two-year sentence.

What went wrong? You both acted rationally, choosing the best option, yet no one wins. _If only_ you could have agreed to cooperate! That way, you would both get one year instead of two. But the temptation to break the trust is too great, so it will never work.[^1]

# Applications

If you keep an eye out for it, the prisoner's dilemma seems to show up everywhere. As one example, consider advertising. Although the effective goal of all advertising is to increase sales, there are some cases where it is only done to lure customers away from competitors. We would end up buying these products even if they weren't advertised, but the advertisements influence which company we go to. More advertising helps the company's market share, but only _relative_ to the amount of advertising that their competitors are doing. If no one advertised, they would all save a lot of money, and (all others things being equal) the market would divide up equally among them. What happens instead is that they all invest in advertising, but each company does approximately the same amount of it, so customers are pulled in all directions at once. However, no company can afford to _not_ advertise, because then the temptation is open to other companies, and the sucker's payoff is swiftly delivered.

The practice of doping in professional sports can also be modelled as a prisoner's dilemma. Performance-enhancing drugs can give one player a significant advantage over another, but that is no longer true if both players use them. In that case, they both suffer the side effects (and run the risk of getting caught) while gaining nothing. The pattern is always the same: players would be better off cooperating, but the nature of the dilemma and its payoffs leads them to inevitable mutual defection.

# Iterated game

We have seen that the dominant strategy in the prisoner's dilemma is to always defect. It's too risky to cooperate, because we have no clue about the intentions of the other player. This all changes in the _iterated_ prisoner's dilemma. In this version, the same two players repeatedly play the game, choosing to cooperate or to defect on each turn.

Before it was just a blind choice, but now there are infinitely many strategies that players can follow. We'll see how they work mathematically, then implement a few as programs. Let the real numbers $R$, $T$, $S$, and $P$ represent the reward, temptation, sucker's payoff, and punishment, respectively, where $S < P < R < T$. Cooperation will be represented by the number 1, and defection by 2. Then, given the choices of two players $x,y\in\{1,2\}$, the payoff for $x$ is defined by $A(x,y) = M_{x,y}$, where

$$M = \begin{bmatrix}R & S \\ T & P \end{bmatrix}$$

is the payoff matrix that I mentioned earlier. Next, we define a <dfn>strategy</dfn> to be a function $s\colon H\to\{1,2\}$, where $H$ is the set of all possible histories. By <dfn>history</dfn> I mean the sequence of moves that have been made so far by both players. Consider two strategies $s_x$ and $s_y$ that generate the sequences  $x_i$ and $y_i$, where $i=0$ represents the first move in the game. Then we can quantitatively compare the strategies simply by keeping score as they play against each other. Specifically, we will calculate the quantity

$$K(s_x,s_y) = \lim_{N\to\infty}\,\frac1N\,\sum_{i=0}^N A(x_i,y_i).$$

If $K(a,b)>K(b,a)$, then we conclude that the strategy $a$ generally wins against the strategy $b$. Note that this does not imply that one is "better" than the other. It's entirely possible that $a$ is a terrible strategy that happens to beat $b$ but loses against everyone else, whereas $b$ is vulnerable to $a$ but otherwise very good. Now, what is the meaning of $K(a,a)$? It tells us how well $a$ plays against itself, but swapping the arguments makes no difference, so we cannot say $a$ wins or loses against itself. In this case, we can interpret $K$ as a measure of cooperation, since by symmetry the temptation and sucker's payoff never occur -- the only payoffs are the reward and the punishment.[^2]

# Scheme implementation

First, we'll define some constants from the payoff matrix:

```scheme
(define reward 2)
(define temptation 3)
(define suckers-payoff 0)
(define punishment 1)

(define cooperate 1)
(define defect 2)
```

Next, we'll implement the history object. A <dfn>history</dfn> is a list of moves from newest to oldest. A <dfn>move</dfn> is an object containing the choices made by both players on that turn, and we'll represent it by a list of two items:

```scheme
(define make-move list)
(define me car)
(define them cadr)
```

I'm also going to include a function to flip the perspective of a move object, so that "me" and "them" are swapped:

```scheme
(define (swap move)
  (make-move (them move) (me move)))
```

Now we can implement the payoff lookup function $A(x,y)$:

```scheme
(define (payoff move)
  (case move
    [((1 1)) reward]
    [((2 1)) temptation]
    [((1 2)) suckers-payoff]
    [((2 2)) punishment]))
```

Next, we'll implement $K(s_1,s_2)$. This function simulates $n$ turns of the iterated game and returns the sum of all payoffs given to the player using the first strategy, divided by $n$. It has a nice recursive structure:

```scheme
(define (calc-k s1 s2 n)
  (define (total turns hist1 hist2 score)
    (if (zero? turns)
        score
        (let ([move (make-move (s1 hist1) (s2 hist2))])
          (total (sub1 turns)
                 (cons move hist1)
                 (cons (swap move) hist2)
                 (+ score (payoff move))))))
  (/ (total n '() '() 0) n))
```

Notice that we maintain two history lists, since each strategy must see the history from its perspective. Finally, we'll include a function that creates a matrix of the values of $K$ by simulating a round-robin strategy tournament. This will let us see the performance of different strategies at a glance.

```scheme
(define (tournament strategies n)
  (map (lambda (s1)
         (map (lambda (s2)
                (calc-k s1 s2 n))
              strategies))
       strategies))
```

# A few strategies

Let's start with some extremely simple strategies. Recall that a strategy takes a history object as input and returns its choice (cooperate or defect). The <i>nice</i> and <i>mean</i> strategies are so simple that they don't even look at the history; <i>alternate</i> is very slightly more sophisticated:

```scheme
(define (nice hist) cooperate)
(define (mean hist) defect)
(define (alternate hist)
  (if (even? (length hist))
      cooperate
      defect))
```

Another strategy is <i>tit for tat</i>. It starts off by cooperating, but after that it simply copies the last move made by its opponent. It seems simple, but it is surprisingly good!

```scheme
(define (tit-for-tat hist)
  (if (null? hist)
      cooperate
      (them (car hist))))
```

Here's the matrix we get using the `tournament` function:

![Tournament matrix with four strategies and 1000 iterations (first player on the left)](../assets/svg/tournament.svg)

# Conclusion

We could get much more creative with these strategies. Our little tournament seemed to suggest that <i>mean</i> is a good strategy, but  this is not entirely true. The numbers are misleading because they give equal weight to all the games. The score against <i>nice</i>, for example, shouldn't be taken too seriously since it is such a weak opponent. The <i>mean</i> strategy may exploit kindness better than the others, but it does not fare well in the larger world of prisoner's dilemma strategies. In fact, it turns out that altruistic, forgiving strategies generally do much better than greedy strategies!

I first learned about the prisoner's dilemma in the chapter "Nice guys finish first" of <cite>The Selfish Gene</cite> by Richard Dawkins. His writing discusses many more strategies for the iterated game, making reference to an actual tournament between strategies submitted by experts in game theory, conducted by Robert Axelrod in the 1980s. He uses instances of the prisoner's dilemma in nature to explain why animals behave altruistically. If these games and strategies interest you, I highly recommend the book.

[^1]: Keep in mind that this is often a simplistic model. We are ignoring all factors of human psychology other than the ideas of rationality and self-interest.

[^2]: This is all assuming that the strategies are pure functions of the game history. If we instead consider them as arbitrary stateful programs that are allowed to incorporate randomness, then the symmetry can be broken.
