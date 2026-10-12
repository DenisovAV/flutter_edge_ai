// The contract every JS skill implements: the agent calls this function with
// the `data` string the model wrote, and expects a JSON string back with one
// of `result` (text for the model), `image` (base64), `webview` or `error`.
window['ai_edge_gallery_get_result'] = async (data) => {
  try {
    const input = JSON.parse(data);
    const total = Number(input.total);
    const people = Number(input.people);
    const tipPercent = Number(input.tip_percent ?? 0);
    // Rejected, not rounded: 2.5 people rounded to 3 is a plausible wrong
    // answer, and the model would pass it on with confidence.
    if (!(total > 0) || !Number.isInteger(people) || people < 1 ||
        !(tipPercent >= 0)) {
      return JSON.stringify({
        error: 'Need a positive total, a whole number of people (1 or more) ' +
          'and a tip of 0 or more.',
      });
    }
    const tip = total * tipPercent / 100;
    const withTip = total + tip;
    const each = withTip / people;
    return JSON.stringify({
      result: `Each of ${people} pays ${each.toFixed(2)} ` +
        `(bill ${total.toFixed(2)} + tip ${tip.toFixed(2)} = ${withTip.toFixed(2)}).`,
    });
  } catch (e) {
    return JSON.stringify({error: `Could not split the bill: ${e.message}`});
  }
};
