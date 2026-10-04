// dart format off
// ignore_for_file: type=lint

// GENERATED FILE, DO NOT MODIFY
// Generated with jaspr_builder

import 'package:jaspr/server.dart';
import 'package:fluttergemma_website/codelabs/codelabs_page.dart'
    as _codelabs_page;
import 'package:fluttergemma_website/components/clicker.dart' as _clicker;
import 'package:fluttergemma_website/landing/sections/cta_section.dart'
    as _cta_section;
import 'package:fluttergemma_website/landing/sections/examples.dart'
    as _examples;
import 'package:fluttergemma_website/landing/sections/features.dart'
    as _features;
import 'package:fluttergemma_website/landing/sections/hero.dart' as _hero;
import 'package:fluttergemma_website/landing/sections/models_gallery.dart'
    as _models_gallery;
import 'package:fluttergemma_website/landing/sections/nav_bar.dart' as _nav_bar;
import 'package:fluttergemma_website/landing/sections/platform_matrix.dart'
    as _platform_matrix;
import 'package:fluttergemma_website/landing/sections/quick_start.dart'
    as _quick_start;
import 'package:fluttergemma_website/landing/sections/renamed_bar.dart'
    as _renamed_bar;
import 'package:fluttergemma_website/landing/sections/site_footer.dart'
    as _site_footer;
import 'package:fluttergemma_website/landing/sections/trust_bar.dart'
    as _trust_bar;
import 'package:fluttergemma_website/landing/sections/why_on_device.dart'
    as _why_on_device;
import 'package:fluttergemma_website/landing/landing_page.dart'
    as _landing_page;
import 'package:jaspr_content/components/_internal/code_block_copy_button.dart'
    as _code_block_copy_button;
import 'package:jaspr_content/components/_internal/zoomable_image.dart'
    as _zoomable_image;
import 'package:jaspr_content/components/callout.dart' as _callout;
import 'package:jaspr_content/components/code_block.dart' as _code_block;
import 'package:jaspr_content/components/github_button.dart' as _github_button;
import 'package:jaspr_content/components/image.dart' as _image;
import 'package:jaspr_content/components/sidebar_toggle_button.dart'
    as _sidebar_toggle_button;
import 'package:jaspr_content/components/theme_toggle.dart' as _theme_toggle;

/// Default [ServerOptions] for use with your Jaspr project.
///
/// Use this to initialize Jaspr **before** calling [runApp].
///
/// Example:
/// ```dart
/// import 'main.server.options.dart';
///
/// void main() {
///   Jaspr.initializeApp(
///     options: defaultServerOptions,
///   );
///
///   runApp(...);
/// }
/// ```
ServerOptions get defaultServerOptions => ServerOptions(
  clientId: 'main.client.dart.js',
  clients: {
    _clicker.Clicker: ClientTarget<_clicker.Clicker>('clicker'),
    _code_block_copy_button.CodeBlockCopyButton:
        ClientTarget<_code_block_copy_button.CodeBlockCopyButton>(
          'jaspr_content:code_block_copy_button',
        ),
    _zoomable_image.ZoomableImage: ClientTarget<_zoomable_image.ZoomableImage>(
      'jaspr_content:zoomable_image',
      params: __zoomable_imageZoomableImage,
    ),
    _github_button.GitHubButton: ClientTarget<_github_button.GitHubButton>(
      'jaspr_content:github_button',
      params: __github_buttonGitHubButton,
    ),
    _sidebar_toggle_button.SidebarToggleButton:
        ClientTarget<_sidebar_toggle_button.SidebarToggleButton>(
          'jaspr_content:sidebar_toggle_button',
        ),
    _theme_toggle.ThemeToggle: ClientTarget<_theme_toggle.ThemeToggle>(
      'jaspr_content:theme_toggle',
    ),
  },
  styles: () => [
    ..._codelabs_page.CodelabsPage.styles,
    ..._clicker.ClickerState.styles,
    ..._landing_page.LandingPage.styles,
    ..._cta_section.CtaSection.styles,
    ..._examples.Examples.styles,
    ..._features.Features.styles,
    ..._hero.Hero.styles,
    ..._models_gallery.ModelsGallery.styles,
    ..._nav_bar.NavBar.styles,
    ..._platform_matrix.PlatformMatrix.styles,
    ..._quick_start.QuickStart.styles,
    ..._renamed_bar.RenamedBar.styles,
    ..._site_footer.SiteFooter.styles,
    ..._trust_bar.TrustBar.styles,
    ..._why_on_device.WhyOnDevice.styles,
    ..._callout.Callout.styles,
    ..._code_block.CodeBlock.styles,
    ..._github_button.GitHubButton.styles,
    ..._image.Image.styles,
    ..._theme_toggle.ThemeToggleState.styles,
    ..._zoomable_image.ZoomableImage.styles,
  ],
);

Map<String, Object?> __zoomable_imageZoomableImage(
  _zoomable_image.ZoomableImage c,
) => {'src': c.src, 'alt': c.alt, 'caption': c.caption};
Map<String, Object?> __github_buttonGitHubButton(
  _github_button.GitHubButton c,
) => {'repo': c.repo};
