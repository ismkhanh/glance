// Decides what a spoken command is: an answer to a question, an update to a task, or a new task.

export const ACTIVE = new Set(['queued', 'running', 'asking', 'paused', 'verifying']);
export const FINISHED = new Set(['done', 'failed']);
export const REOPEN_WINDOW_MS = 10 * 60 * 1000;

const AGREE = /^(yes|yeah|yep|ok|okay|sure|fine|do it|go ahead|sounds good|your (choice|pick|recommendation)|recommended|the recommended( one)?|whatever you (think|recommend)|go with (that|it|yours|your pick))\b/;

function words(text) {
  return String(text).toLowerCase().replace(/[^a-z0-9\s'-]/g, ' ').split(/\s+/).filter(Boolean);
}

/**
 * The option the words pick, or null. "horizontal", "make it horizontal", "the first one", "2",
 * "yes" (→ the recommendation) all count.
 */
export function matchOption(text, question) {
  if (!question) return null;
  const options = question.options || [];
  const t = String(text).toLowerCase().trim().replace(/[.!?]+$/, '');
  if (!t) return null;
  if (AGREE.test(t) && question.recommended) return question.recommended;
  const ordinals = [['first', '1'], ['second', '2'], ['third', '3'], ['fourth', '4']];   // not "one": "the blue one"
  const w = words(t);
  for (let i = 0; i < options.length && i < ordinals.length; i++) {
    if (w.length <= 3 && w.some((x) => ordinals[i].includes(x))) return options[i];
  }
  let best = null;
  for (const option of options) {
    const o = String(option).toLowerCase();
    const ow = words(o);
    // The whole option said ("horizontal"), or its first word ("horizontal" for "Horizontal scroll").
    if (t.includes(o) || (ow[0] && ow[0].length > 2 && w.includes(ow[0]))) {
      if (best === null) best = option;
      else return null;            // fits two options: not a clear answer
    }
  }
  return best;
}

/** Short replies (3 words or fewer) are answers when a question is open; longer ones must name an option. */
export function looksLikeAnswer(text, question) {
  if (matchOption(text, question)) return true;
  return words(text).length <= 3 && !/\b(make|turn|change|set|add|remove)\b/i.test(String(text));
}

const UNDO = /^(please |ok |okay |no |oh |hmm |um )*(undo|revert|put (it|that|this) back|change (it|that|this) back|take (it|that) back|go back)( (it|that|this|please|again))*$/;

/** "undo that", "put it back", "revert": the whole utterance asks to undo, nothing more. */
export function isUndo(text) {
  return UNDO.test(String(text).toLowerCase().replace(/[.,!?]+/g, ' ').replace(/\s+/g, ' ').trim());
}

/**
 * text: what was said. answerTo: task id whose tooltip the pointer was on. target: layer pointed at (or null).
 * Returns {kind: 'answer'|'update'|'undo'|'new', taskId?}. Undo goes to the task on the layer pointed at,
 * else to the task changed last; it puts the layers back from the saved copy (the worker is not asked).
 */
export function route({ text, answerTo, target, tasks, now = Date.now() }) {
  if (isUndo(text)) {
    const undoable = tasks.filter((t) => ACTIVE.has(t.status) || (FINISHED.has(t.status) && now - t.updatedAt <= REOPEN_WINDOW_MS))
      .sort((a, b) => b.updatedAt - a.updatedAt);
    const onLayer = target?.id ? undoable.find((t) => t.target?.id === target.id) : null;
    const task = onLayer || undoable[0];
    return task ? { kind: 'undo', taskId: task.id } : { kind: 'undo' };
  }
  if (answerTo) {
    const t = tasks.find((x) => x.id === answerTo);
    if (t && (t.status === 'asking' || (t.status === 'paused' && t.question))) return { kind: 'answer', taskId: t.id };
  }
  if (target?.id) {
    const sameLayer = tasks.filter((t) => t.target?.id === target.id);
    const active = sameLayer.filter((t) => ACTIVE.has(t.status)).sort((a, b) => b.updatedAt - a.updatedAt)[0];
    if (active) {
      if (active.question && (active.status === 'asking' || active.status === 'paused') && looksLikeAnswer(text, active.question)) {
        return { kind: 'answer', taskId: active.id };
      }
      return { kind: 'update', taskId: active.id };
    }
    const recent = sameLayer
      .filter((t) => FINISHED.has(t.status) && now - t.updatedAt <= REOPEN_WINDOW_MS)
      .sort((a, b) => b.updatedAt - a.updatedAt)[0];
    if (recent) return { kind: 'update', taskId: recent.id };
    return { kind: 'new' };
  }
  const asking = tasks.filter((t) => t.status === 'asking');
  if (asking.length === 1 && matchOption(text, asking[0].question)) return { kind: 'answer', taskId: asking[0].id };
  return { kind: 'new' };
}
