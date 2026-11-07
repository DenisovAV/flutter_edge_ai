import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../../theme/brand.dart';
import 'submit_api.dart';

enum _Phase { editing, sending, sent }

/// The form on `/showcase/submit`. It sends the fields to the
/// `submitShowcaseApp` function, which checks them again, finds the app in
/// its store and stores the submission for review.
///
/// The browser checks what it can first: the required fields, the URL and
/// email formats and the lengths. At least one store link is checked here.
@client
class ShowcaseSubmitForm extends StatefulComponent {
  const ShowcaseSubmitForm({super.key});

  @override
  State<ShowcaseSubmitForm> createState() => ShowcaseSubmitFormState();
}

class ShowcaseSubmitFormState extends State<ShowcaseSubmitForm> {
  final _api = ShowcaseSubmitApi();

  // Text fields keep what was typed without a rebuild; a rebuild for another
  // field renders these values back.
  String _googlePlayUrl = '';
  String _appStoreUrl = '';
  String _appName = '';
  String _sourceUrl = '';
  String _onDevice = '';
  String _email = '';
  final _packages = <String>{};
  bool _isDeveloper = false;
  bool _consent = false;

  _Phase _phase = _Phase.editing;
  String? _error;

  Future<void> _submit() async {
    if (_phase != _Phase.editing) return;
    if (_googlePlayUrl.trim().isEmpty && _appStoreUrl.trim().isEmpty) {
      setState(() => _error = 'Give a Google Play or an App Store link.');
      return;
    }
    if (_packages.isEmpty) {
      setState(() => _error = 'Choose flutter_edge_ai, flutter_gemma or both.');
      return;
    }
    setState(() {
      _phase = _Phase.sending;
      _error = null;
    });
    try {
      await _api.submit({
        'googlePlayUrl': _googlePlayUrl,
        'appStoreUrl': _appStoreUrl,
        'appName': _appName,
        'sourceUrl': _sourceUrl,
        'packages': _packages.toList(),
        'onDevice': _onDevice,
        'email': _email,
        'isDeveloper': _isDeveloper,
        'consent': _consent,
      });
      setState(() => _phase = _Phase.sent);
    } on SubmitException catch (e) {
      setState(() {
        _phase = _Phase.editing;
        _error = e.message;
      });
    } catch (e) {
      // App Check, the network or the SDK; the person can only try again.
      print('Showcase submission failed: $e');
      setState(() {
        _phase = _Phase.editing;
        _error = 'The submission could not be sent. Try again later.';
      });
    }
  }

  @override
  Component build(BuildContext context) {
    if (_phase == _Phase.sent) {
      return div(
        classes: 'ss-done',
        attributes: {'role': 'status'},
        [
          h2(classes: 'ss-done-title', [Component.text('Thank you')]),
          p(classes: 'ss-done-text', [
            Component.text(
              'I check every app before it is listed, and I will write to $_email about it.',
            ),
          ]),
          a(href: '/showcase', classes: 'ss-link', [
            Component.text('Back to the showcase'),
          ]),
        ],
      );
    }
    final sending = _phase == _Phase.sending;
    return form(
      classes: 'ss-form',
      events: {
        'submit': (event) {
          event.preventDefault();
          _submit();
        },
      },
      [
        _text(
          id: 'ss-play',
          caption: 'Google Play link',
          type: InputType.url,
          value: _googlePlayUrl,
          placeholder: 'https://play.google.com/store/apps/details?id=…',
          onInput: (v) => _googlePlayUrl = v,
        ),
        _text(
          id: 'ss-appstore',
          caption: 'App Store link',
          type: InputType.url,
          value: _appStoreUrl,
          placeholder: 'https://apps.apple.com/…/app/…/id…',
          hint: 'At least one of the two.',
          onInput: (v) => _appStoreUrl = v,
        ),
        _text(
          id: 'ss-name',
          caption: 'App name (optional)',
          value: _appName,
          maxLength: 100,
          hint: 'Leave it empty to use the name in the store.',
          onInput: (v) => _appName = v,
        ),
        _text(
          id: 'ss-source',
          caption: 'Source code on GitHub (optional)',
          type: InputType.url,
          value: _sourceUrl,
          placeholder: 'https://github.com/…/…',
          hint: 'If the app is open source: its pubspec.yaml is checked for flutter_edge_ai or flutter_gemma.',
          onInput: (v) => _sourceUrl = v,
        ),
        fieldset(classes: 'ss-fieldset', [
          legend(classes: 'ss-label', [Component.text('Built with')]),
          for (final package in const ['flutter_edge_ai', 'flutter_gemma'])
            _checkbox(
              id: 'ss-package-$package',
              checked: _packages.contains(package),
              onChange: (v) => setState(
                () => v ? _packages.add(package) : _packages.remove(package),
              ),
              [
                code([Component.text(package)]),
              ],
            ),
        ]),
        div(classes: 'ss-field', [
          label(htmlFor: 'ss-on-device', classes: 'ss-label', [
            Component.text('What runs on the device'),
          ]),
          textarea(
            id: 'ss-on-device',
            classes: 'ss-input ss-textarea',
            required: true,
            rows: 4,
            placeholder: 'For example: Gemma 3 1B answers questions about your notes, offline.',
            attributes: const {'maxlength': '500'},
            onInput: (v) => _onDevice = v,
            [Component.text(_onDevice)],
          ),
        ]),
        _text(
          id: 'ss-email',
          caption: 'Your email',
          type: InputType.email,
          value: _email,
          required: true,
          maxLength: 254,
          autoComplete: 'email',
          hint: 'Only to write to you about this listing. Deleted on request.',
          onInput: (v) => _email = v,
        ),
        _checkbox(
          id: 'ss-developer',
          checked: _isDeveloper,
          required: true,
          onChange: (v) => setState(() => _isDeveloper = v),
          [Component.text('I develop or publish this app.')],
        ),
        _checkbox(
          id: 'ss-consent',
          checked: _consent,
          required: true,
          onChange: (v) => setState(() => _consent = v),
          [
            Component.text(
              'The app\'s name, icon and store links may be shown on flutteredge.ai/showcase. '
              'I can ask for it to be removed at any time.',
            ),
          ],
        ),
        if (_error case final error?)
          p(
            classes: 'ss-error',
            attributes: {'role': 'alert'},
            [Component.text(error)],
          ),
        button(
          type: ButtonType.submit,
          classes: 'ss-submit',
          disabled: sending,
          [Component.text(sending ? 'Sending…' : 'Submit')],
        ),
      ],
    );
  }

  static Component _text({
    required String id,
    required String caption,
    required String value,
    required void Function(String) onInput,
    InputType type = InputType.text,
    bool required = false,
    int? maxLength,
    String? placeholder,
    String? autoComplete,
    String? hint,
  }) {
    final hintId = '$id-hint';
    return div(classes: 'ss-field', [
      label(htmlFor: id, classes: 'ss-label', [Component.text(caption)]),
      input<String>(
        id: id,
        type: type,
        value: value,
        classes: 'ss-input',
        attributes: {
          if (required) 'required': '',
          if (maxLength != null) 'maxlength': '$maxLength',
          'placeholder': ?placeholder,
          'autocomplete': ?autoComplete,
          if (hint != null) 'aria-describedby': hintId,
        },
        onInput: onInput,
      ),
      if (hint != null) p(id: hintId, classes: 'ss-hint', [Component.text(hint)]),
    ]);
  }

  static Component _checkbox(
    List<Component> text, {
    required String id,
    required bool checked,
    required void Function(bool) onChange,
    bool required = false,
  }) {
    return div(classes: 'ss-check', [
      input<bool>(
        id: id,
        type: InputType.checkbox,
        checked: checked,
        classes: 'ss-checkbox',
        attributes: {if (required) 'required': ''},
        onChange: onChange,
      ),
      label(htmlFor: id, classes: 'ss-check-label', text),
    ]);
  }

  @css
  static List<StyleRule> get styles => [
    css('.ss-form').styles(
      display: Display.flex,
      maxWidth: 640.px,
      flexDirection: FlexDirection.column,
      gap: Gap.all(1.25.rem),
    ),
    css('.ss-field').styles(
      display: Display.flex,
      flexDirection: FlexDirection.column,
      gap: Gap.all(0.4.rem),
    ),
    css('.ss-label').styles(
      padding: Padding.zero,
      color: Brand.white,
      fontFamily: Brand.fontSans,
      fontSize: 0.95.rem,
      fontWeight: FontWeight.w600,
    ),
    css('.ss-input').styles(
      padding: Padding.symmetric(horizontal: 0.85.rem, vertical: 0.65.rem),
      border: Border.all(color: Color('rgba(255,255,255,0.18)'), width: 1.px),
      radius: BorderRadius.circular(10.px),
      color: Brand.white,
      fontFamily: Brand.fontSans,
      fontSize: 1.rem,
      backgroundColor: Color('rgba(255,255,255,0.05)'),
    ),
    css('.ss-input::placeholder').styles(color: Brand.white50),
    css(
      '.ss-input:focus-visible, .ss-checkbox:focus-visible, .ss-submit:focus-visible',
    ).styles(
      raw: {
        'outline': '2px solid ${Brand.blueLight.value}',
        'outline-offset': '2px',
      },
    ),
    css('.ss-textarea').styles(raw: {'resize': 'vertical', 'min-height': '6rem'}),
    css('.ss-hint').styles(
      margin: Margin.zero,
      color: Brand.white50,
      fontFamily: Brand.fontSans,
      fontSize: 0.82.rem,
    ),
    css('.ss-fieldset').styles(
      display: Display.flex,
      padding: Padding.zero,
      margin: Margin.zero,
      border: Border.none,
      flexDirection: FlexDirection.column,
      gap: Gap.all(0.5.rem),
    ),
    css('.ss-check').styles(
      display: Display.flex,
      flexDirection: FlexDirection.row,
      alignItems: AlignItems.start,
      gap: Gap.all(0.6.rem),
    ),
    css('.ss-checkbox').styles(
      width: 1.1.rem,
      height: 1.1.rem,
      margin: Margin.only(top: 0.15.rem),
      raw: {'flex-shrink': '0', 'accent-color': Brand.blue.value},
    ),
    css('.ss-check-label').styles(
      color: Brand.white70,
      fontFamily: Brand.fontSans,
      fontSize: 0.95.rem,
      lineHeight: 1.5.em,
    ),
    css(
      '.ss-check-label code',
    ).styles(color: Brand.white, fontFamily: Brand.fontMono, fontSize: 0.92.em),
    css('.ss-error').styles(
      margin: Margin.zero,
      padding: Padding.symmetric(horizontal: 0.85.rem, vertical: 0.65.rem),
      border: Border.all(color: Color('rgba(248,113,113,0.5)'), width: 1.px),
      radius: BorderRadius.circular(10.px),
      color: Color('#fecaca'),
      fontFamily: Brand.fontSans,
      fontSize: 0.95.rem,
      backgroundColor: Color('rgba(248,113,113,0.1)'),
    ),
    css('.ss-submit').styles(
      padding: Padding.symmetric(horizontal: 1.6.rem, vertical: 0.75.rem),
      border: Border.none,
      radius: BorderRadius.circular(999.px),
      cursor: Cursor.pointer,
      color: Brand.white,
      fontFamily: Brand.fontSans,
      fontSize: 1.rem,
      fontWeight: FontWeight.w700,
      backgroundColor: Brand.blue,
      raw: {'align-self': 'flex-start'},
    ),
    css('.ss-submit:disabled').styles(cursor: Cursor.wait, opacity: 0.6),
    css('.ss-done').styles(
      display: Display.flex,
      maxWidth: 640.px,
      flexDirection: FlexDirection.column,
      gap: Gap.all(0.75.rem),
    ),
    css('.landing-root .ss-done-title').styles(
      margin: Margin.zero,
      color: Brand.white,
      fontFamily: Brand.fontSans,
      fontSize: 1.5.rem,
      fontWeight: FontWeight.w700,
    ),
    css('.ss-done-text').styles(
      margin: Margin.zero,
      color: Brand.white70,
      fontFamily: Brand.fontSans,
      fontSize: 1.rem,
      lineHeight: 1.6.em,
    ),
    css('.ss-link').styles(
      color: Brand.blueLight,
      fontFamily: Brand.fontSans,
      fontWeight: FontWeight.w600,
    ),
  ];
}
