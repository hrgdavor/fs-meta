// The segment dynamic program the matcher uses. A COPY of `gitignore/js/glob.mjs` at gitignore v0.2.0: the same rule
// as js/gitignore.mjs applies - change it in the gitignore project, then refresh both files here.
// The segment dynamic program, ported from the Zig reference — with the allocations removed.
//
// The first version was correct and *slower* than the regex it replaced: it split the path inside every rule and
// allocated two arrays per pattern segment, and in a 2,000-path run that allocation is the cost. This version splits the
// path once per decision (the caller does it), reuses two scratch arrays, and lets a caller ask about the first `count`
// segments so the directory-only ancestor check needs no second split.

/**
 * Compile one pattern into the form the DP wants: an array of `{ doubleStar }` or `{ regex }` entries, in order.
 *
 * @param {string} glob the pattern, with any leading `/` already removed
 * @param {boolean} anchored whether the pattern is anchored to the walk root
 * @param {(segment: string) => string} translate one segment to a regex body (the port's own translator)
 */
export function compileSegments(glob, anchored, translate) {
  const segments = glob.split('/').map((segment) =>
    segment === '**' ? { doubleStar: true } : { regex: new RegExp(`^${translate(segment)}$`) },
  );
  // An unanchored pattern applies at any depth, which is a leading `**` and nothing else.
  return anchored ? segments : [{ doubleStar: true }, ...segments];
}

// Two scratch rows, reused across calls: the DP needs a "previous" and a "next" row and nothing else. They grow to the
// longest path seen and are never freed, which is the point — allocation was the cost, not the comparison.
let scratchA = [];
let scratchB = [];

function rows(size) {
  if (scratchA.length < size) {
    scratchA = new Array(size).fill(false);
    scratchB = new Array(size).fill(false);
  }
  return [scratchA, scratchB];
}

/**
 * Does the compiled pattern match the first `count` segments of `text`?
 *
 * @param {Array<{doubleStar?: boolean, regex?: RegExp}>} segments
 * @param {string[]} text a path already split on `/`
 * @param {number} [count] how many segments to consider (default: all of them)
 */
export function segmentsMatch(segments, text, count = text.length) {
  const [first, second] = rows(count + 1);
  let reach = first;
  let next = second;
  for (let index = 0; index <= count; index += 1) reach[index] = index === 0;

  for (let index = 0; index < segments.length; index += 1) {
    const segment = segments[index];
    for (let position = 0; position <= count; position += 1) next[position] = false;

    if (segment.doubleStar === true) {
      const last = index === segments.length - 1;
      let any = false;
      for (let position = 0; position <= count; position += 1) {
        // A trailing `**` is one-or-more (`build/**` is inside build), a middle one is zero-or-more.
        if (last) next[position] = any;
        if (reach[position]) any = true;
        if (!last) next[position] = any;
      }
    } else {
      for (let position = 0; position < count; position += 1) {
        if (reach[position] && segment.regex.test(text[position])) next[position + 1] = true;
      }
    }

    const swap = reach;
    reach = next;
    next = swap;
  }

  return reach[count];
}