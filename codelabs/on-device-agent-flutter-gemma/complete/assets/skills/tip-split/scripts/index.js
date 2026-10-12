// The contract every JS skill implements: the agent calls this function with
// the `data` string the model wrote, and expects a JSON string back with one
// of `result` (text for the model), `image` ({base64: a data: URL}),
// `webview` ({url, iframe}) or `error` (text the model reads and acts on).
window['ai_edge_gallery_get_result'] = async (data) => {
  try {
    const input = JSON.parse(data);
    // Nothing is guessed. A tip sent under the wrong key and read as 0, or
    // 2.5 people rounded to 3, is a plausible wrong answer the model would
    // pass on with confidence; an error naming the field makes it call again.
    const extra = Object.keys(input).filter(
      (key) => !['total', 'people', 'tip_percent'].includes(key));
    if (extra.length > 0) {
      return fail(`unexpected field ${extra.join(', ')}; the fields are ` +
        'total, people and tip_percent');
    }
    const total = toNumber(input.total);
    const people = toNumber(input.people);
    const tipPercent = toNumber(input.tip_percent);
    if (!(total > 0 && total < 1e9)) {
      return fail('"total" must be a number above 0 and below 1000000000');
    }
    if (!Number.isInteger(people) || people < 1 || people > 1000) {
      return fail('"people" must be a whole number from 1 to 1000');
    }
    if (!(tipPercent >= 0 && tipPercent <= 100)) {
      return fail('"tip_percent" must be a number from 0 to 100; send 0 ' +
        'when the user gave no tip');
    }
    // In cents, so the shares add up to the bill: what does not divide
    // evenly is said, not rounded away.
    const billCents = Math.round(total * 100);
    const totalCents = Math.round(total * (100 + tipPercent));
    const eachCents = Math.floor(totalCents / people);
    const extraCents = totalCents - eachCents * people;
    let result = `Each of ${people} pays ${money(eachCents)} ` +
      `(bill ${money(billCents)} + tip ${money(totalCents - billCents)} = ` +
      `${money(totalCents)}).`;
    if (extraCents > 0) {
      result += extraCents === 1
        ? ' One of them pays one cent more.'
        : ` ${extraCents} of them pay one cent more.`;
    }
    return JSON.stringify({result});
  } catch (e) {
    return fail(`could not split the bill: ${e.message}`);
  }
};

// A number, or a string holding one; anything else — null, "", true — is NaN.
function toNumber(value) {
  if (typeof value === 'number') return value;
  if (typeof value === 'string' && value.trim() !== '') return Number(value);
  return NaN;
}

function money(cents) {
  return (cents / 100).toFixed(2);
}

function fail(message) {
  return JSON.stringify({error: message});
}
