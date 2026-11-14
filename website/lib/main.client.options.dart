// dart format off
// ignore_for_file: type=lint

// GENERATED FILE, DO NOT MODIFY
// Generated with jaspr_builder

import 'package:jaspr/client.dart';

import 'package:fluttergemma_website/components/clicker.dart'
    deferred as _clicker;
import 'package:fluttergemma_website/components/play_when_visible.dart'
    deferred as _play_when_visible;
import 'package:fluttergemma_website/landing/sections/nav_bar.dart'
    deferred as _nav_bar;
import 'package:fluttergemma_website/showcase/submit/submit_form.dart'
    deferred as _submit_form;
import 'package:fluttergemma_website/showcase/showcase_browser.dart'
    deferred as _showcase_browser;
import 'package:jaspr_content/components/_internal/code_block_copy_button.dart'
    deferred as _code_block_copy_button;
import 'package:jaspr_content/components/_internal/zoomable_image.dart'
    deferred as _zoomable_image;
import 'package:jaspr_content/components/github_button.dart'
    deferred as _github_button;
import 'package:jaspr_content/components/sidebar_toggle_button.dart'
    deferred as _sidebar_toggle_button;
import 'package:jaspr_content/components/theme_toggle.dart'
    deferred as _theme_toggle;

/// Default [ClientOptions] for use with your Jaspr project.
///
/// Use this to initialize Jaspr **before** calling [runApp].
///
/// Example:
/// ```dart
/// import 'main.client.options.dart';
///
/// void main() {
///   Jaspr.initializeApp(
///     options: defaultClientOptions,
///   );
///
///   runApp(...);
/// }
/// ```
ClientOptions get defaultClientOptions => ClientOptions(
  clients: {
    'clicker': ClientLoader(
      (p) => _clicker.Clicker(),
      loader: _clicker.loadLibrary,
    ),
    'play_when_visible': ClientLoader(
      (p) => _play_when_visible.PlayWhenVisible(),
      loader: _play_when_visible.loadLibrary,
    ),
    'nav_bar': ClientLoader(
      (p) => _nav_bar.NavBar(),
      loader: _nav_bar.loadLibrary,
    ),
    'showcase_browser': ClientLoader(
      (p) => _showcase_browser.ShowcaseBrowser(),
      loader: _showcase_browser.loadLibrary,
    ),
    'submit_form': ClientLoader(
      (p) => _submit_form.ShowcaseSubmitForm(),
      loader: _submit_form.loadLibrary,
    ),
    'jaspr_content:code_block_copy_button': ClientLoader(
      (p) => _code_block_copy_button.CodeBlockCopyButton(),
      loader: _code_block_copy_button.loadLibrary,
    ),
    'jaspr_content:zoomable_image': ClientLoader(
      (p) => _zoomable_image.ZoomableImage(
        src: p.get<String>('src'),
        alt: p.get<String?>('alt'),
        caption: p.get<String?>('caption'),
      ),
      loader: _zoomable_image.loadLibrary,
    ),
    'jaspr_content:github_button': ClientLoader(
      (p) => _github_button.GitHubButton(repo: p.get<String>('repo')),
      loader: _github_button.loadLibrary,
    ),
    'jaspr_content:sidebar_toggle_button': ClientLoader(
      (p) => _sidebar_toggle_button.SidebarToggleButton(),
      loader: _sidebar_toggle_button.loadLibrary,
    ),
    'jaspr_content:theme_toggle': ClientLoader(
      (p) => _theme_toggle.ThemeToggle(),
      loader: _theme_toggle.loadLibrary,
    ),
  },
);
