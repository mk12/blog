---
title: Cracking the Caesar cipher
subtitle: How to crack a Caesar cipher using frequency analysis
category: Algorithms
date: 2015-03-30T15:52:37-04:00
---

Whenever I play around with a new language, I like to start by writing a program to crack a Caesar cipher. This problem is perfect for getting a sense of what it's like to work in a given language. It's significantly more interesting than "Hello, World!" but it only takes about a hundred lines to write -- in fact, the line count by itself is a good indication of how expressive the language is.

You might have heard of the ROT-13 cipher, where you rotate each letter around the alphabet by 13 positions. The result of doing this to the plaintext (message) is called the ciphertext (coded message). The Caesar cipher generalizes this to numbers other than 13. We only need to consider numbers between 0 and 25, since adding multiples of 26 makes no difference. Notice that with the Caesar cipher, we have to distinguish between encryption and decryption -- one goes forwards and the other goes backwards. The exceptions are 0, which is pretty useless, and 13, which is ROT-13.

The Caesar cipher is a special case of the substitution cipher, which maps all possible pieces of plaintext (usually single letters, but not always) to corresponding pieces of ciphertext. There are only 26 Caesar ciphers; on the other hand, there 26! possible letter substitution ciphers.[^1] Our goal is to crack a Caesar-encrypted message, which means to find its _key_, the rotation number used to encrypt it. We can easily do this by brute force, by trying all 26 possible keys. The result of decrypting the message will almost certainly be gibberish for all but one key, but how can a computer recognize plausible English?

You could try each key and do a dictionary check on the results. This would work, since the true message should have by far the most English words in it. However, we're going to use a different method: _frequency analysis_. Most English writing uses all 26 letters, but it's never a uniform distribution -- <i>e</i> is far more common than <i>z</i>, for example. We can exploit this fact to crack the Caesar cipher by scoring each of the 26 potential plaintexts for its likeness to English, based on letter frequencies. But how should we calculate this score? We could just count the occurrences of <i>e</i>, but there is a better way.

We begin by computing the relative frequencies of the 26 letters. Each relative frequency is a fraction between zero and one, and when we add all 26 of them together we get 1.0. For example, the relative frequencies of the string "AB" in alphabetical order are 0.5, 0.5, and 24 zeros. Since the whole point of this exercise is to test drive fun languages, I'm going to implement the algorithm in [Haskell][hs], a purely functional language. Check out my [Caesar project][go] written in Go to see an imperative approach.

```haskell
import Data.Char (toLower)
import Data.List (genericLength)
import qualified Data.Map as M

relativeFreqs :: (Fractional a) => String -> [a]
relativeFreqs s = freqs
  where
    letters  = filter (`elem` ['a'..'z']) . map toLower $ s
    zeros    = M.fromDistinctAscList $ map (flip (,) 0) ['a'..'z']
    inc m x  = M.adjust (+ 1) x m
    counts   = M.elems $ foldl inc zeros letters
    divide n = fromIntegral n / genericLength letters
    freqs    = map divide counts
```

First, the type signature: the function `relativeFreqs` takes a string (list of characters) and returns a list of `a`, where `a` is a fractional type. We could say it returns a `Float` list, but it's better to be as general as possible. Now, we convert the string to lower case and throw out letters that aren't in the alphabet. Next, we create a `Map` -- maps in Haskell are like dictionaries or hash tables in other languages. This maps each letter of the alphabet to zero. Then we define `inc` which takes a map and a letter and increases the value associated with that letter by one. We [fold] the list of letters with this function, producing a map that associates letters with the number of times they occur in the original string. Finally, we take those count values and divide them all by the total number of letters to get the relative frequencies.

The relative frequencies will be different for every text, but not _that_ different -- the longer the text, the more likely it is to resemble the characteristic English distribution. Imagine if we could find the relative frequencies from all 3,563,505,777,820 letters scanned by Google Books; that's exactly what [Peter Norvig did][freqs]! Here's the frequencies he came up with, expressed as percentages to avoid writing so many zeros:

```
[8.04, 1.48, 3.34, 3.82, 12.49, 2.40, 1.87, 5.05, 7.57, 0.16, 0.54, 4.07, 2.51,
 7.23, 7.64, 2.14, 0.12, 6.28,  6.51, 9.28, 2.73, 1.05, 1.68, 0.23, 1.66, 0.09]
```

Now we know what the correct frequencies should look like, but how do we measure the distance between two sets of relative frequencies? One idea would be to add up the absolute differences letter-wise. That might work, but I'm going to jump straight to the best method: Pearson's chi-squared test. We calculate the cumulative chi-squared test-statistic by

$$χ^2 = \sum_{i=1}^n\frac{(O_i - E_i)^2}{E_i}$$

where $n=26$ is the number of frequencies, $O_i$ is an observed frequency, and $E_i$ is the corresponding expected frequency. The lower the value of $χ^2$, the closer the match. In our case, the $O_i$ values are the relative frequencies of the potential plaintext and the $E_i$ values come from the Google Books data. Let's implement that:

```haskell
chiSqr :: (Fractional a) => [a] -> [a] -> a
chiSqr es os = sum $ zipWith term es os
    where term e o = (o - e)^2 / e
```

This takes two lists of relative frequencies (expected and observed) and returns the test-statistic. The `zipWith` function is like `map` but it takes a binary operator and two lists instead of a unary operator and one list. The `sum` function does exactly what you would expect: it adds up all the elements of the list.

Before we write a cracking function, we'll need to implement a decryption function. This will rely on `shift`, which rotates a character around the alphabet by the given number of positions. While we're at it, let's write an encryption function as well:

```haskell
import Data.Char (chr, ord)

shift :: Int -> Char -> Char
shift n c
    | c `elem` ['a'..'z'] = chr $ ord 'a' + (ord c - ord 'a' + n) `mod` 26
    | c `elem` ['A'..'Z'] = chr $ ord 'A' + (ord c - ord 'A' + n) `mod` 26
    | otherwise           = c

encrypt :: Int -> String -> String
encrypt = map . shift

decrypt :: Int -> String -> String
decrypt = map . shift . negate
```

The `ord` function returns a character's ASCII value, and `chr` does the opposite conversion. We subtract the value of <i>a</i> to get a number between 0 and 25, then we do modular addition of the shift value, and finally we convert back to a character. The encryption function partially applies its input to `shift`, which then gets mapped over the string. Decryption is similar, but negates the number first (since decryption goes backwards). These two functions are written in the [point-free style][pf],[^2] much loved by Haskellers -- it's easy to read once you're used to it.

We're almost there. We just need two more functions. The `rotate` function will rotate a list around by a given number of positions. The `minIndex` function will return the index of the smallest element in the list:

```haskell
import Data.List (minimumBy)
import Data.Ord (comparing)

rotate :: [a] -> Int -> [a]
rotate xs n = back ++ front where (front, back) = splitAt n xs

minIndex :: (Ord a) => [a] -> Int
minIndex = fst . minimumBy (comparing snd) . zip [0..]
```

We use `splitAt` to break the list and two, and then we reassemble them in the opposite order. We calculate the minimum index by zipping the list with the natural numbers (that's right, `[0..]` is an infinite list), finding the minimum element judging by the original items, and then extracting the zipped index. Now, take a deep breath...

It's time to crack the Caesar cipher!

```haskell
crack :: String -> Int
crack s = minIndex chis
  where
    freqs = relativeFreqs s
    chis  = map (chiSqr englishFreqs . rotate freqs) [0..25]
```

First we find the relative frequencies. Next, we try all possible rotations and calculate the test-statistic for each one, where `englishFreqs` is the frequency list we talked about earlier. Finally, we return the index of the best one. The secret message is just one call to `decrypt` away!

I encourage you to try encrypting any English text you like and seeing if the cracker works. It's hit-or-miss for extremely short strings, but incredibly accurate for substantial amounts of text. Only classical ciphers are so easily cracked by frequency analysis, and no one uses them anymore for obvious reasons, but I think it's a fun problem regardless. If you're new to Haskell, I hoped this has piqued your interest; and be sure to take a look at the [Go implementation][go] if you're more comfortable with that.

[^1]: That's 26 factorial, approximately 4×10<sup>26</sup> -- one substitution cipher for each of the atoms in your body, give or take. And that's just the English alphabet!

[^2]: Witty people refer to it as the _pointless_ style.

[hs]: https://www.haskell.org/
[go]: https://github.com/mk12/caesar
[fold]: https://wiki.haskell.org/Fold
[freqs]: https://norvig.com/mayzner.html
[pf]: https://wiki.haskell.org/Pointfree
