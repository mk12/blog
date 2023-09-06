---
title: Shopify co-op reflection
subtitle: Belated thoughts on my first internship
category: Life
---

Well, "at least one article a week" clearly didn't last for long. After publishing my [first year reflection](first-year.md), I was really intending to write a reflection post after each term, or at least once a year -- but it never happened. To fix that, I've decided to go back and write the articles I didn't have time or motivation for before, starting with my first co-op: Shopify.

# Onboarding

May 4, 2015 -- _May the 4th be with you_. I'm not really a Star Wars fan, but I remember the first day of the internship fell on that day. I arrived at 150 Elgin Street by 10:00 a.m., and made my way to the eighth floor. Exiting the elevator, I faced a large comic strip poster:

> Suddenly, the doors opened...<br>
> Exit from that primitive transportation device.<br>
> You have arrived at the **Shopify Mothership**!

That was (and still is, as far as I know) one of many pieces of artwork decorating [the Shopify office][1]. Together with the speakeasy-themed seventh floor and the house-shaped pair programming rooms, the cushioned nooks in walls and the bear bean bag chairs, the hammocks and the indoor go-kart track, they make for a unique tech office.

There were around thirty other interns starting that day, including a few of my classmates from Waterloo. We waited in the Lounge, and then broke off into smaller groups for onboarding. Seated around a table, we each got a bag containing a Shopify T-shirt and hoodie, a Moleskine notepad and pen, an Apple keyboard and mouse, and a MacBook Pro. Then we went around the table having everyone introduce themselves. (That probably included telling the dreaded "fun fact" about yourself.) Finally, we learned about Shopify's core values -- the first and most memorable, "Get shit done."

For the rest of that day, and for most of the first week, we spent our time in Cody's Café on the sixth floor. There, we set up our development environments, learned about Shopify's architecture and infrastructure, listened to talks by full-time engineers, and worked through coding exercises. We also set up our own Shopify stores. I called mine H2G2, short for _The Hitchhiker's Guide to the Galaxy_, one of my favourite books. I was surprised to find that, almost 3 years later, [the site is still up][2]!

# Platform team

On Friday, onboarding was over and real work started. I was assigned to the Platform team, which is responsible for a variety of things involving partners of Shopify. Among those things is [Shopify Experts][3], a website that connects merchants with experts who can help them with their stores in areas such as design, marketing, and photography. I spent most of my internship working on the Experts website. It looks a bit different now, but the main feature I implemented is still there.

On that first day, the first thing I did was cut my finger trying to open the Apple keyboard. I was trying to cut the plastic by running my fingernail along an edge, but instead it cut me. Having found a bandaid, I got on with setting up my desk and meeting my teammates. There were around ten or twelve of us, pretty well evenly split between developers and designers. It was a bit crowded in that room, but just a few days later our team moved to a much bigger "pod" on the other end of the seventh floor. Further away from kitchen but closer to the stairs, so worth it overall, was the verdict.

I shipped a change to production that first Friday. It was a small change, but it was still pretty neat to ship it on the first day. I used the Shipit tool, which Shopify has since [made open source][4]. Each company I've interned at since Shopify has had a different deployment process, but none were this fast. This style, called continuous delivery, has a lot of advantages, but it only makes sense for certain types of software. A web app whose tests finish in ten minutes minutes falls in that category; a piece of critical infrastructure whose build takes hours doesn't.

# IPO & Hack Days

An exciting part of interning at Shopify was experiencing its IPO. On Thursday, May 21, Shopify went public at $17 a share on the New York Stock Exchange. (If you had invested at that price, you would be very happy now, since [SHOP][5] is trading at nearly $150 as of early March 2018.) That day at work, we celebrated with a breakfast of bacon, eggs, pancakes, and mimosas. There were TVs showing what was going on in New York, so we saw them ring the bell to start the trading.

The special occasion wasn't just the IPO. It was also Hack Days, the internal hackathon Shopify holds a few times a year. I had already joined a team with another intern and a full time employee. After breakfast, we reserved a room called Mushroom Kingdom and got to work. Our idea was to make an app that would use an alpha matting algorithm to automatically remove the background from an image. This could be useful for product images in a shop -- you can do it manually in Photoshop, but it's tedious. I didn't know anything about image processing, so I was happy to try this out and learn about it.

We continued working on the project through Friday, but unfortunately didn't finish in time. We still did a demo to pitch the idea and show our progress, but faked it by swapping the [bunny picture][6] with a hand-masked version instead of actually running the unfinished algorithm on it. Not surprisingly, we didn't advance to the later rounds of voting and judging, but it was fun to watch the other demos and vote on them. I can't remember which project won in the end.

# Culture (?)

thurs eng Talks, friday town hall, side kicks, slack

mindfulness

intern trip

crime and punishment

# What next?

learned stuff

debating return offer

try different things. 6 coops

[1]: http://www.linebox.ca/work/shopify/
[2]: https://h2g2.myshopify.com/
[3]: https://experts.shopify.com/
[4]: https://shopifyengineering.myshopify.com/blogs/engineering/introducing-shipit
[5]: https://www.bloomberg.com/quote/SHOP:US
[6]: http://animal-central.wikia.com/wiki/File:Bunnies-bunny-rabbits-16437969-1280-800.jpg
