import {
  NGFControlStyleTokens,
  NGFMaterialSurfaceTokens,
  ngfVisualEffectsFacade,
  uiContextManager
} from 'ngf_framework';
import { ASFWorkshopProductIdentity, SteamArkLog } from '../../steamServices';
import { SteamArkTheme } from './SteamArkTheme';

export class SteamArkLegalSheetKind {
  static readonly ABOUT: number = 0;
  static readonly USER_AGREEMENT: number = 1;
  static readonly PRIVACY: number = 2;
  static readonly OPEN_SOURCE: number = 3;
}

@Component
export struct SteamArkLegalSheetContent {
  @Prop kind: number = SteamArkLegalSheetKind.ABOUT;
  @State private linkStatusVisible: boolean = false;
  @State private linkStatus: ResourceStr = '';
  @State private openingLinkId: string = '';
  @StorageProp('ngf_is_dark_mode') private isDarkMode: boolean = false;
  @StorageProp('ngf_visual_effects_should_use_system_material_surface') private useSysMat: boolean = true;
  private isActive: boolean = false;
  private lifecycleGeneration: number = 0;

  aboutToAppear(): void {
    this.isActive = true;
    this.lifecycleGeneration += 1;
    this.linkStatusVisible = false;
    this.openingLinkId = '';
  }

  aboutToDisappear(): void {
    this.isActive = false;
    this.lifecycleGeneration += 1;
  }

  build(): void {
    Column({ space: 0 }) {
      this.buildHeader();
      Scroll() {
        Column({ space: 12 }) {
          if (this.linkStatusVisible) {
            this.buildLinkStatus();
          }
          this.buildSheetSections();
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 20 });
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring);
    }
    .width('100%')
    .height('100%')
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceElevated(this.isDarkMode),
      this.useSysMat
    ))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareSheetBackgroundEffect(this.useSysMat))
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForProminentPanel());
  }

  @Builder
  private buildHeader(): void {
    Column({ space: 5 }) {
      Row({ space: 9 }) {
        SymbolGlyph(this.headerIcon())
          .fontSize(20)
          .fontColor([SteamArkTheme.accent(this.isDarkMode)]);
        Text(this.headerTitle())
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
          .layoutWeight(1);
      }
      .width('100%');
      Text(this.headerSubtitle())
        .width('100%')
        .fontSize(13)
        .lineHeight(19)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode));
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 8 });
  }

  @Builder
  private buildLinkStatus(): void {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.info_circle'))
        .fontSize(17)
        .fontColor([SteamArkTheme.error(this.isDarkMode)]);
      Text(this.linkStatus)
        .layoutWeight(1)
        .fontSize(13)
        .lineHeight(19)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode));
    }
    .width('100%')
    .padding(12)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceControl(this.isDarkMode),
      this.useSysMat
    ))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareControlBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
    .border({
      width: NGFMaterialSurfaceTokens.buildMaterialAwareBorderWidth(1, this.useSysMat),
      color: NGFMaterialSurfaceTokens.buildMaterialAwareBorderColor(
        SteamArkTheme.error(this.isDarkMode),
        this.useSysMat
      )
    })
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForLightEffectControl());
  }

  @Builder
  private buildSheetSections(): void {
    if (this.kind === SteamArkLegalSheetKind.USER_AGREEMENT) {
      this.buildUserAgreementSections();
    } else if (this.kind === SteamArkLegalSheetKind.PRIVACY) {
      this.buildPrivacySections();
    } else if (this.kind === SteamArkLegalSheetKind.OPEN_SOURCE) {
      this.buildOpenSourceSections();
    } else {
      this.buildAboutSections();
    }
  }

  @Builder
  private buildAboutSections(): void {
    this.buildNoticeCard(
      $r('app.string.steam_legal_about_overview_title'),
      $r('app.string.steam_legal_about_overview_desc')
    );
    this.buildNoticeCard(
      $r('app.string.steam_legal_about_independence_title'),
      $r('app.string.steam_legal_about_independence_desc')
    );
    this.buildSupportCard();
    this.buildDeveloperAppsCard();
  }

  @Builder
  private buildUserAgreementSections(): void {
    this.buildNoticeCard(
      $r('app.string.steam_legal_user_scope_title'),
      $r('app.string.steam_legal_user_scope_desc')
    );
    this.buildNoticeCard(
      $r('app.string.steam_legal_user_service_title'),
      $r('app.string.steam_legal_user_service_desc')
    );
    this.buildNoticeCard(
      $r('app.string.steam_legal_user_safe_use_title'),
      $r('app.string.steam_legal_user_safe_use_desc')
    );
    this.buildNoticeCard(
      $r('app.string.steam_legal_user_high_risk_title'),
      $r('app.string.steam_legal_user_high_risk_desc')
    );
    this.buildNoticeCard(
      $r('app.string.steam_legal_user_update_title'),
      $r('app.string.steam_legal_user_update_desc')
    );
    this.buildNoticeCard(
      $r('app.string.steam_legal_user_disclaimer_title'),
      $r('app.string.steam_legal_user_disclaimer_desc')
    );
  }

  @Builder
  private buildPrivacySections(): void {
    this.buildNoticeCard(
      $r('app.string.steam_legal_privacy_sensitive_title'),
      $r('app.string.steam_legal_privacy_sensitive_desc')
    );
    this.buildNoticeCard(
      $r('app.string.steam_legal_privacy_cache_title'),
      $r('app.string.steam_legal_privacy_cache_desc')
    );
    this.buildNoticeCard(
      $r('app.string.steam_legal_privacy_network_title'),
      $r('app.string.steam_legal_privacy_network_desc')
    );
    this.buildNoticeCard(
      $r('app.string.steam_legal_privacy_system_title'),
      $r('app.string.steam_legal_privacy_system_desc')
    );
    this.buildNoticeCard(
      $r('app.string.steam_legal_privacy_choice_title'),
      $r('app.string.steam_legal_privacy_choice_desc')
    );
  }

  @Builder
  private buildOpenSourceSections(): void {
    this.buildNoticeCard(
      $r('app.string.steam_legal_source_app_title'),
      $r('app.string.steam_legal_source_app_desc')
    );
    this.buildNoticeCard(
      $r('app.string.steam_legal_source_core_title'),
      $r('app.string.steam_legal_source_core_desc')
    );
    this.buildNoticeCard(
      $r('app.string.steam_legal_source_trademark_title'),
      $r('app.string.steam_legal_source_trademark_desc')
    );
    this.buildNoticeCard(
      $r('app.string.steam_legal_source_thirdparty_title'),
      $r('app.string.steam_legal_source_thirdparty_desc')
    );
    this.buildRepositoryCard();
  }

  @Builder
  private buildNoticeCard(title: ResourceStr, description: ResourceStr): void {
    Column({ space: 7 }) {
      Text(title)
        .width('100%')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode));
      Text(description)
        .width('100%')
        .fontSize(13)
        .lineHeight(20)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode));
    }
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceElevated(this.isDarkMode),
      this.useSysMat
    ))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .border({
      width: NGFMaterialSurfaceTokens.buildMaterialAwareBorderWidth(1, this.useSysMat),
      color: NGFMaterialSurfaceTokens.buildMaterialAwareBorderColor(
        SteamArkTheme.divider(this.isDarkMode),
        this.useSysMat
      )
    })
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel());
  }

  @Builder
  private buildSupportCard(): void {
    Column({ space: 10 }) {
      Text($r('app.string.steam_legal_about_support_title'))
        .width('100%')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode));
      Text($r('app.string.steam_legal_about_support_desc'))
        .width('100%')
        .fontSize(13)
        .lineHeight(20)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode));
      this.buildExternalActionButton(
        $r('app.string.steam_legal_about_support_action'),
        ASFWorkshopProductIdentity.AFDIAN_URL,
        'steam-ark-legal-open-afdian'
      );
    }
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceElevated(this.isDarkMode),
      this.useSysMat
    ))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .border({
      width: NGFMaterialSurfaceTokens.buildMaterialAwareBorderWidth(1, this.useSysMat),
      color: NGFMaterialSurfaceTokens.buildMaterialAwareBorderColor(
        SteamArkTheme.divider(this.isDarkMode),
        this.useSysMat
      )
    })
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel());
  }

  @Builder
  private buildDeveloperAppsCard(): void {
    Column({ space: 10 }) {
      Text($r('app.string.steam_legal_about_developer_apps_title'))
        .width('100%')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode));
      Text($r('app.string.steam_legal_about_developer_apps_desc'))
        .width('100%')
        .fontSize(13)
        .lineHeight(20)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode));
      this.buildDeveloperAppRow(
        $r('app.string.steam_legal_developer_manxia_name'),
        $r('app.string.steam_legal_developer_manxia_desc'),
        ASFWorkshopProductIdentity.MANXIA_APP_GALLERY_URL,
        'steam-ark-legal-open-manxia'
      );
      Divider().color(SteamArkTheme.divider(this.isDarkMode));
      this.buildDeveloperAppRow(
        $r('app.string.steam_legal_developer_lumabloom_name'),
        $r('app.string.steam_legal_developer_lumabloom_desc'),
        ASFWorkshopProductIdentity.LUMABLOOM_APP_GALLERY_URL,
        'steam-ark-legal-open-lumabloom'
      );
      Divider().color(SteamArkTheme.divider(this.isDarkMode));
      this.buildDeveloperAppRow(
        $r('app.string.steam_legal_developer_book_name'),
        $r('app.string.steam_legal_developer_book_desc'),
        ASFWorkshopProductIdentity.BOOK_VEIN_APP_GALLERY_URL,
        'steam-ark-legal-open-book-vein'
      );
    }
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceElevated(this.isDarkMode),
      this.useSysMat
    ))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .border({
      width: NGFMaterialSurfaceTokens.buildMaterialAwareBorderWidth(1, this.useSysMat),
      color: NGFMaterialSurfaceTokens.buildMaterialAwareBorderColor(
        SteamArkTheme.divider(this.isDarkMode),
        this.useSysMat
      )
    })
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel());
  }

  @Builder
  private buildDeveloperAppRow(
    title: ResourceStr,
    description: ResourceStr,
    url: string,
    elementId: string
  ): void {
    Column({ space: 8 }) {
      Text(title)
        .width('100%')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode));
      Text(description)
        .width('100%')
        .fontSize(12)
        .lineHeight(18)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode));
      this.buildExternalActionButton($r('app.string.steam_legal_about_gallery_action'), url, elementId);
    }
    .width('100%');
  }

  @Builder
  private buildRepositoryCard(): void {
    Column({ space: 10 }) {
      Text($r('app.string.steam_legal_source_repositories_title'))
        .width('100%')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode));
      Text($r('app.string.steam_legal_source_repositories_desc'))
        .width('100%')
        .fontSize(13)
        .lineHeight(20)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode));
      this.buildExternalActionButton(
        $r('app.string.steam_legal_source_workshop_repo'),
        ASFWorkshopProductIdentity.ASF_WORKSHOP_REPOSITORY_URL,
        'steam-ark-legal-open-workshop-repository'
      );
      this.buildExternalActionButton(
        $r('app.string.steam_legal_source_core_repo'),
        ASFWorkshopProductIdentity.OPEN_HARMONY_ASF_REPOSITORY_URL,
        'steam-ark-legal-open-core-repository'
      );
    }
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceElevated(this.isDarkMode),
      this.useSysMat
    ))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .border({
      width: NGFMaterialSurfaceTokens.buildMaterialAwareBorderWidth(1, this.useSysMat),
      color: NGFMaterialSurfaceTokens.buildMaterialAwareBorderColor(
        SteamArkTheme.divider(this.isDarkMode),
        this.useSysMat
      )
    })
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel());
  }

  @Builder
  private buildExternalActionButton(title: ResourceStr, url: string, elementId: string): void {
    Button() {
      Row({ space: 8 }) {
        if (this.openingLinkId === elementId) {
          LoadingProgress()
            .width(16)
            .height(16)
            .color(SteamArkTheme.accentCyan(this.isDarkMode));
        } else {
          SymbolGlyph($r('sys.symbol.link'))
            .fontSize(16)
            .fontColor([SteamArkTheme.accentCyan(this.isDarkMode)]);
        }
        Text(title)
          .layoutWeight(1)
          .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
          .fontColor(SteamArkTheme.buttonForeground(this.isDarkMode))
          .textAlign(TextAlign.Start);
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([SteamArkTheme.textSecondary(this.isDarkMode)]);
      }
      .width('100%')
      .padding({ left: 12, right: 12 });
    }
    .width('100%')
    .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
    .padding(0)
    .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceControl(this.isDarkMode),
      this.useSysMat
    ))
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForFloatingControl())
    .enabled(this.openingLinkId.length === 0)
    .id(elementId)
    .onClick((): void => {
      void this.openExternalLink(url, elementId);
    });
  }

  private async openExternalLink(url: string, elementId: string): Promise<void> {
    if (!this.isActive || this.openingLinkId.length > 0) {
      return;
    }
    const lifecycleGeneration: number = this.lifecycleGeneration;
    const context = uiContextManager.getFullAbilityContext();
    if (context === null) {
      this.linkStatus = $r('app.string.steam_legal_link_unavailable');
      this.linkStatusVisible = true;
      SteamArkLog.warn('LegalSheet', 'external link skipped because UIAbilityContext is unavailable');
      return;
    }
    this.openingLinkId = elementId;
    this.linkStatusVisible = false;
    try {
      await context.openLink(url, { appLinkingOnly: false });
      SteamArkLog.info('LegalSheet', 'external link opened; id=' + elementId);
    } catch (_error) {
      if (this.isActive && this.lifecycleGeneration === lifecycleGeneration) {
        this.linkStatus = $r('app.string.steam_legal_link_failed');
        this.linkStatusVisible = true;
      }
      SteamArkLog.warn('LegalSheet', 'external link opening failed; id=' + elementId);
    } finally {
      if (this.isActive && this.lifecycleGeneration === lifecycleGeneration) {
        this.openingLinkId = '';
      }
    }
  }

  private headerTitle(): ResourceStr {
    switch (this.kind) {
      case SteamArkLegalSheetKind.USER_AGREEMENT:
        return $r('app.string.steam_legal_user_title');
      case SteamArkLegalSheetKind.PRIVACY:
        return $r('app.string.steam_legal_privacy_title');
      case SteamArkLegalSheetKind.OPEN_SOURCE:
        return $r('app.string.steam_legal_source_title');
      case SteamArkLegalSheetKind.ABOUT:
      default:
        return $r('app.string.steam_legal_about_title');
    }
  }

  private headerSubtitle(): ResourceStr {
    switch (this.kind) {
      case SteamArkLegalSheetKind.USER_AGREEMENT:
        return $r('app.string.steam_legal_user_subtitle');
      case SteamArkLegalSheetKind.PRIVACY:
        return $r('app.string.steam_legal_privacy_subtitle');
      case SteamArkLegalSheetKind.OPEN_SOURCE:
        return $r('app.string.steam_legal_source_subtitle');
      case SteamArkLegalSheetKind.ABOUT:
      default:
        return $r('app.string.steam_legal_about_subtitle');
    }
  }

  private headerIcon(): Resource {
    switch (this.kind) {
      case SteamArkLegalSheetKind.USER_AGREEMENT:
        return $r('sys.symbol.doc_text');
      case SteamArkLegalSheetKind.PRIVACY:
        return $r('sys.symbol.lock_shield');
      case SteamArkLegalSheetKind.OPEN_SOURCE:
        return $r('sys.symbol.doc_text_magnifyingglass_fill');
      case SteamArkLegalSheetKind.ABOUT:
      default:
        return $r('sys.symbol.info_circle');
    }
  }
}
