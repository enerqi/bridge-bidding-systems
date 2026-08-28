package render

import (
	"regexp"
	"strings"
)

// EmojiTextAuction and its regexes are copied from `apps/quiz/quiz_app.py` (via the python
// port's `render.py`) rather than shared -- that module imports panel. It is
// presentation-only, and the copy is the one piece of deliberate duplication in this port.

// silly, but a button strips excess internal whitespace, so the separator carries its own
const invisibleSeparator = "⁣"

var bidSeparator = strings.Repeat(invisibleSeparator, 4) + "‣" + strings.Repeat(invisibleSeparator, 4)

var (
	// link text stays, link target goes
	linkTargetRE = regexp.MustCompile(`\(#.*\)`)
	wordClubRE   = regexp.MustCompile(`\bC `)
	wordDiaRE    = regexp.MustCompile(`\bD `)
	wordHeartRE  = regexp.MustCompile(`\bH `)
	wordSpadeRE  = regexp.MustCompile(`\bS `)
)

// suitReplaceInBids is the python `_suit_replace_regex` pass:
//
//	\d ( [CDHS] | N(?!T) )+
//
// a digit followed by one or more denominations, with the suit letters becoming glyphs and
// a bare `N` becoming `NT`. Hand-written rather than a regexp because RE2 has no negative
// lookahead, and the lookahead is what keeps an already-spelled `1NT` from becoming `1NTT`.
func suitReplaceInBids(text string) string {
	var out strings.Builder
	out.Grow(len(text))
	for i := 0; i < len(text); {
		ch := text[i]
		if ch >= '0' && ch <= '9' {
			end := i + 1
			for end < len(text) {
				d := text[end]
				if d == 'C' || d == 'D' || d == 'H' || d == 'S' {
					end++
					continue
				}
				if d == 'N' && (end+1 >= len(text) || text[end+1] != 'T') {
					end++
					continue
				}
				break
			}
			if end > i+1 {
				out.WriteByte(ch)
				for k := i + 1; k < end; k++ {
					switch text[k] {
					case 'C':
						out.WriteString(Club)
					case 'D':
						out.WriteString(Diamond)
					case 'H':
						out.WriteString(Heart)
					case 'S':
						out.WriteString(Spade)
					case 'N':
						out.WriteString("NT")
					}
				}
				i = end
				continue
			}
		}
		out.WriteByte(ch)
		i++
	}
	return out.String()
}

var loneSuitReplacer = strings.NewReplacer(
	" C ", " "+Club+" ",
	" D ", " "+Diamond+" ",
	" H ", " "+Heart+" ",
	" S ", " "+Spade+" ",
)

var pluralSuitReplacer = strings.NewReplacer(
	"Cs", Club+"s",
	"Ds", Diamond+"s",
	"Hs", Heart+"s",
	"Ss", Spade+"s",
)

var shorthandSuitReplacer = strings.NewReplacer("!c", Club, "!d", Diamond, "!h", Heart, "!s", Spade)

// EmojiTextAuction turns one auction (or one description) into the text the card shows:
// suit letters become glyphs, the `-->` joiner becomes the arrow separator, and markdown
// link targets are dropped.
func EmojiTextAuction(auction string) string {
	a := auction

	if strings.Count(auction, "(") == 1 && strings.Count(auction, ")") == 1 && strings.Contains(auction, "(Pass)") {
		// superfluous (pass); better fixed in the data source, or by making all opposition
		// bids explicit
		a = strings.ReplaceAll(a, "(Pass)", bidSeparator)
	}

	a = suitReplaceInBids(a)
	a = shorthandSuitReplacer.Replace(a)
	a = loneSuitReplacer.Replace(a)

	a = wordClubRE.ReplaceAllString(a, Club+" ")
	a = wordDiaRE.ReplaceAllString(a, Diamond+" ")
	a = wordHeartRE.ReplaceAllString(a, Heart+" ")
	a = wordSpadeRE.ReplaceAllString(a, Spade+" ")

	a = pluralSuitReplacer.Replace(a)

	a = strings.ReplaceAll(a, "-->", bidSeparator)
	a = strings.ReplaceAll(a, "--", "-")

	a = strings.ReplaceAll(a, "[", "")
	a = strings.ReplaceAll(a, "]", "")
	return linkTargetRE.ReplaceAllString(a, "")
}
