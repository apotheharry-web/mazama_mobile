//! Step 1 of the parsing algorithm (specs/coa/04-parsing.md): words -> lines, in reading order, across pages.
//!
//! A word joins a line when the two overlap vertically by at least half the smaller height, so words of different
//! sizes on one printed line ("Sample: Shakti" and "UID: PL-7c737a92" on Rose City reports, about a point apart)
//! stay together. Lines are ordered top to bottom and pages follow each other, so a section that starts at the foot
//! of one page continues at the top of the next.
//!
//! Running headers and footers (the same text, digits ignored, at the same place on two or more pages, inside the
//! top or bottom margin) are *flagged*, not removed: sections skip them, but report-level fields such as the
//! "Reported:" date live in exactly those repeated headers.

use crate::coa::text::{CoaText, Word};
use std::collections::{HashMap, HashSet};

/// The fraction of the page height, at the top and at the bottom, where running headers and footers may sit.
const MARGIN_TOP: f64 = 0.20;
const MARGIN_BOTTOM: f64 = 0.10;
/// Two repeated lines count as "the same place" when their tops are this close, in points.
const SAME_PLACE: f64 = 4.0;

#[derive(Debug, Clone, PartialEq)]
pub struct Line {
    pub page: usize,
    pub y0: f64,
    pub y1: f64,
    pub words: Vec<Word>,
    /// A running header or footer: repeated on several pages in the margin.
    pub repeated: bool,
}

impl Line {
    /// The words joined by single spaces, left to right.
    pub fn text(&self) -> String {
        self.words.iter().map(|w| w.text.as_str()).collect::<Vec<_>>().join(" ")
    }
    pub fn x0(&self) -> f64 {
        self.words.first().map_or(0.0, |w| w.x0)
    }
}

fn overlap(a0: f64, a1: f64, b0: f64, b1: f64) -> f64 {
    (a1.min(b1) - a0.max(b0)).max(0.0)
}

/// One page's words grouped into lines, top to bottom, each line's words left to right.
fn page_lines(page: usize, words: &[Word]) -> Vec<Line> {
    let mut ws: Vec<&Word> = words.iter().collect();
    ws.sort_by(|a, b| a.center_y().total_cmp(&b.center_y()).then(a.x0.total_cmp(&b.x0)));
    let mut lines: Vec<Line> = Vec::new();
    for w in ws {
        let h = w.height();
        // the open line this word overlaps most (only recent lines can: words arrive in vertical order)
        let best = lines
            .iter()
            .enumerate()
            .rev()
            .take_while(|(_, l)| l.y1 + h >= w.y0)
            .map(|(i, l)| {
                let lh = l.words.iter().map(Word::height).fold(f64::INFINITY, f64::min);
                (i, overlap(l.y0, l.y1, w.y0, w.y1) / h.min(lh).max(0.01))
            })
            .filter(|(_, r)| *r >= 0.5)
            .max_by(|a, b| a.1.total_cmp(&b.1))
            .map(|(i, _)| i);
        match best {
            Some(i) => {
                let l = &mut lines[i];
                l.y0 = l.y0.min(w.y0);
                l.y1 = l.y1.max(w.y1);
                l.words.push(w.clone());
            }
            None => lines.push(Line { page, y0: w.y0, y1: w.y1, words: vec![w.clone()], repeated: false }),
        }
    }
    for l in &mut lines {
        l.words.sort_by(|a, b| a.x0.total_cmp(&b.x0));
    }
    lines.sort_by(|a, b| a.y0.total_cmp(&b.y0).then(a.x0().total_cmp(&b.x0())));
    lines
}

/// Text with every digit replaced by '#', so "Page 2 of 9" and "Page 3 of 9" are the same footer.
fn shape(text: &str) -> String {
    text.chars().map(|c| if c.is_ascii_digit() { '#' } else { c }).collect()
}

/// Every line of the report in reading order, running headers and footers flagged.
pub fn lines(t: &CoaText) -> Vec<Line> {
    let mut out: Vec<Line> = Vec::new();
    let mut heights: HashMap<usize, f64> = HashMap::new();
    for p in &t.pages {
        heights.insert(p.index, p.height);
        out.extend(page_lines(p.index, &p.words));
    }
    // which pages each margin line's shape appears on, at about the same height
    let in_margin = |l: &Line| {
        let h = heights[&l.page];
        l.y0 < h * MARGIN_TOP || l.y1 > h * (1.0 - MARGIN_BOTTOM)
    };
    let mut pages_of: HashMap<String, Vec<(usize, f64)>> = HashMap::new();
    for l in out.iter().filter(|l| in_margin(l)) {
        pages_of.entry(shape(&l.text())).or_default().push((l.page, l.y0));
    }
    for l in out.iter_mut() {
        if !in_margin(l) {
            continue;
        }
        let seen = &pages_of[&shape(&l.text())];
        let others: HashSet<usize> =
            seen.iter().filter(|(p, y)| *p != l.page && (y - l.y0).abs() <= SAME_PLACE).map(|(p, _)| *p).collect();
        l.repeated = !others.is_empty();
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::coa::text::{Page, Source};

    fn w(text: &str, x0: f64, y0: f64, h: f64) -> Word {
        Word { text: text.into(), x0, y0, x1: x0 + 8.0 * text.len() as f64, y1: y0 + h, conf: None }
    }

    fn doc(pages: Vec<Vec<Word>>) -> CoaText {
        CoaText {
            version: 1,
            source_sha256: "0".repeat(64),
            extractor: None,
            pages: pages
                .into_iter()
                .enumerate()
                .map(|(i, words)| Page { index: i, width: 612.0, height: 792.0, source: Source::TextLayer, engine: "t".into(), words })
                .collect(),
        }
    }

    #[test]
    fn words_a_point_apart_share_a_line_and_read_left_to_right() {
        let t = doc(vec![vec![w("PL-7c737a92", 413.0, 173.7, 8.4), w("Shakti", 68.7, 174.9, 8.8), w("UID:", 392.3, 174.2, 8.1), w("Sample:", 20.5, 174.9, 8.8)]]);
        let ls = lines(&t);
        assert_eq!(ls.len(), 1);
        assert_eq!(ls[0].text(), "Sample: Shakti UID: PL-7c737a92");
    }

    #[test]
    fn lines_one_row_apart_stay_separate_and_in_order() {
        let t = doc(vec![vec![w("Psilocin", 20.0, 277.0, 6.4), w("Psilocybin", 20.0, 264.7, 6.4), w("13.1", 200.0, 264.7, 6.4)]]);
        let texts: Vec<String> = lines(&t).iter().map(Line::text).collect();
        assert_eq!(texts, ["Psilocybin 13.1", "Psilocin"]);
    }

    #[test]
    fn pages_follow_each_other() {
        let t = doc(vec![vec![w("UID:", 20.0, 690.0, 9.0)], vec![w("Psilocybin", 20.0, 200.0, 9.0)]]);
        let ls = lines(&t);
        assert_eq!((ls[0].page, ls[0].text().as_str()), (0, "UID:"));
        assert_eq!((ls[1].page, ls[1].text().as_str()), (1, "Psilocybin"));
    }

    #[test]
    fn running_footers_are_flagged_whatever_their_page_number() {
        let page = |n: &str| vec![w("Page", 520.0, 763.0, 9.0), w(n, 560.0, 763.0, 9.0), w("UID:", 20.0, 300.0, 9.0)];
        let ls = lines(&doc(vec![page("2"), page("3")]));
        let flagged: Vec<(String, bool)> = ls.iter().map(|l| (l.text(), l.repeated)).collect();
        assert!(flagged.contains(&("Page 2".into(), true)) && flagged.contains(&("Page 3".into(), true)));
        assert!(flagged.iter().filter(|(t, _)| t == "UID:").all(|(_, r)| !r), "body lines are never flagged");
    }

    #[test]
    fn a_line_in_the_margin_on_only_one_page_is_not_flagged() {
        let ls = lines(&doc(vec![vec![w("Reported:", 500.0, 100.0, 9.0)], vec![w("Other", 500.0, 100.0, 9.0)]]));
        assert!(ls.iter().all(|l| !l.repeated));
    }
}
