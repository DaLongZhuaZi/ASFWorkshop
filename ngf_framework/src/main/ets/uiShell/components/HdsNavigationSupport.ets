import {
  BlurStrategy,
  hdsMaterial,
  HdsNavigationBackgroundStyle,
  HdsNavigationTitle,
  HdsNavigationTitleBarOptions,
  HdsNavigationTitleBarStyle,
  HdsNavigationTitleStyle,
  HdsTitleBarContentStyle,
  ScrollEffectOptions,
  ScrollEffectType,
  SystemMaterialParams,
  TitleBarContentOptions,
  TitleBarStyleOptions
} from '@kit.UIDesignKit';
import { NGFHdsEffectPresetFactory } from './NGFHdsEffectPresets';

class NGFHdsNavigationTitle implements HdsNavigationTitle {
  mainTitle: ResourceStr;
  subTitle?: ResourceStr;

  constructor(mainTitle: ResourceStr, subTitle?: ResourceStr) {
    this.mainTitle = mainTitle;
    if (subTitle !== undefined) {
      this.subTitle = subTitle;
    }
  }
}

class NGFHdsNavigationBackgroundStyle implements HdsNavigationBackgroundStyle {
  backgroundColor?: ResourceColor;
  maskExtraHeight?: number;
  blurRadius?: number;

  constructor(backgroundColor: ResourceColor, blurRadius: number) {
    this.backgroundColor = backgroundColor;
    this.maskExtraHeight = 28;
    this.blurRadius = blurRadius;
  }
}

class NGFHdsNavigationTitleStyle implements HdsNavigationTitleStyle {
  mainTitleColor?: ResourceColor;
  subTitleColor?: ResourceColor;
  mainTitleShadowColor?: ResourceColor;
  subTitleShadowColor?: ResourceColor;

  constructor(mainTitleColor: ResourceColor, subTitleColor: ResourceColor) {
    this.mainTitleColor = mainTitleColor;
    this.subTitleColor = subTitleColor;
    this.mainTitleShadowColor = $r('app.color.circle_shadow_light');
    this.subTitleShadowColor = $r('app.color.card_shadow_light');
  }
}

class NGFHdsTitleBarContentStyle implements HdsTitleBarContentStyle {
  titleStyle?: HdsNavigationTitleStyle;

  constructor(titleStyle: HdsNavigationTitleStyle) {
    this.titleStyle = titleStyle;
  }
}

class NGFHdsNavigationTitleBarStyle implements HdsNavigationTitleBarStyle {
  backgroundStyle?: HdsNavigationBackgroundStyle;
  contentStyle?: HdsTitleBarContentStyle;

  constructor(backgroundStyle: HdsNavigationBackgroundStyle, contentStyle: HdsTitleBarContentStyle) {
    this.backgroundStyle = backgroundStyle;
    this.contentStyle = contentStyle;
  }
}

class NGFHdsScrollEffectOptions implements ScrollEffectOptions {
  enableScrollEffect?: boolean;
  scrollEffectType?: ScrollEffectType;

  constructor(scrollEffectType: ScrollEffectType) {
    this.enableScrollEffect = true;
    this.scrollEffectType = scrollEffectType;
  }
}

class NGFHdsTitleBarStyleOptions implements TitleBarStyleOptions {
  scrollEffectOpts?: ScrollEffectOptions;
  originalStyle?: HdsNavigationTitleBarStyle;
  scrollEffectStyle?: HdsNavigationTitleBarStyle;
  blurStrategy?: BlurStrategy;
  thermoCtrl?: boolean;
  systemMaterialEffect?: SystemMaterialParams;

  constructor(
    originalStyle: HdsNavigationTitleBarStyle,
    scrollEffectStyle: HdsNavigationTitleBarStyle,
    systemMaterialEffect?: SystemMaterialParams
  ) {
    this.scrollEffectOpts = new NGFHdsScrollEffectOptions(ScrollEffectType.GRADIENT_BLUR);
    this.originalStyle = originalStyle;
    this.scrollEffectStyle = scrollEffectStyle;
    this.blurStrategy = BlurStrategy.ADAPTIVE;
    this.thermoCtrl = false;
    if (systemMaterialEffect !== undefined) {
      this.systemMaterialEffect = systemMaterialEffect;
    }
  }
}

class NGFHdsTitleBarContentOptions implements TitleBarContentOptions {
  title?: HdsNavigationTitle;

  constructor(title: HdsNavigationTitle) {
    this.title = title;
  }
}

class NGFHdsNavigationTitleBarOptions implements HdsNavigationTitleBarOptions {
  style?: TitleBarStyleOptions;
  content?: TitleBarContentOptions;
  enableHoverMode?: boolean;
  avoidLayoutSafeArea?: boolean;
  enableComponentSafeArea?: boolean;

  constructor(
    content: TitleBarContentOptions,
    style: TitleBarStyleOptions,
    avoidLayoutSafeArea: boolean,
    enableComponentSafeArea: boolean
  ) {
    this.content = content;
    this.style = style;
    this.enableHoverMode = false;
    this.avoidLayoutSafeArea = avoidLayoutSafeArea;
    this.enableComponentSafeArea = enableComponentSafeArea;
  }
}

export class NGFHdsTitleBarOptionsFactory {
  static build(
    mainTitle: ResourceStr,
    subTitle: ResourceStr,
    backgroundColor: ResourceColor,
    materialLevel: hdsMaterial.MaterialLevel,
    avoidLayoutSafeArea: boolean = false,
    enableComponentSafeArea: boolean = false
  ): HdsNavigationTitleBarOptions {
    return NGFHdsTitleBarOptionsFactory.buildInternal(
      mainTitle,
      subTitle,
      backgroundColor,
      materialLevel,
      avoidLayoutSafeArea,
      enableComponentSafeArea,
      $r('app.color.text_white'),
      $r('app.color.glass_chip_overlay'),
      $r('app.color.text_white'),
      $r('app.color.text_white_medium')
    );
  }

  /**
   * Builds a title bar whose foreground follows the page surface theme.
   * The legacy build() method intentionally keeps its dark-glass defaults for
   * existing NGF showcase pages; product shells should use this method when
   * their background resource changes between light and dark qualifiers.
   */
  static buildWithTitleColors(
    mainTitle: ResourceStr,
    subTitle: ResourceStr,
    backgroundColor: ResourceColor,
    materialLevel: hdsMaterial.MaterialLevel,
    mainTitleColor: ResourceColor,
    subTitleColor: ResourceColor,
    avoidLayoutSafeArea: boolean = false,
    enableComponentSafeArea: boolean = false
  ): HdsNavigationTitleBarOptions {
    return NGFHdsTitleBarOptionsFactory.buildInternal(
      mainTitle,
      subTitle,
      backgroundColor,
      materialLevel,
      avoidLayoutSafeArea,
      enableComponentSafeArea,
      mainTitleColor,
      subTitleColor,
      mainTitleColor,
      subTitleColor
    );
  }

  static buildOverContentWithTitleColors(
    mainTitle: ResourceStr,
    subTitle: ResourceStr,
    scrollBackgroundColor: ResourceColor,
    mainTitleColor: ResourceColor,
    subTitleColor: ResourceColor,
    avoidLayoutSafeArea: boolean = false,
    enableComponentSafeArea: boolean = false
  ): HdsNavigationTitleBarOptions {
    const originalTitleStyle = new NGFHdsNavigationTitleStyle(mainTitleColor, subTitleColor);
    const scrollTitleStyle = new NGFHdsNavigationTitleStyle(mainTitleColor, subTitleColor);
    const originalContentStyle = new NGFHdsTitleBarContentStyle(originalTitleStyle);
    const scrollContentStyle = new NGFHdsTitleBarContentStyle(scrollTitleStyle);
    const originalBackgroundStyle = new NGFHdsNavigationBackgroundStyle(Color.Transparent, 0);
    const scrollBackgroundStyle = new NGFHdsNavigationBackgroundStyle(scrollBackgroundColor, 28);
    const originalBarStyle = new NGFHdsNavigationTitleBarStyle(originalBackgroundStyle, originalContentStyle);
    const scrollBarStyle = new NGFHdsNavigationTitleBarStyle(scrollBackgroundStyle, scrollContentStyle);
    const content = new NGFHdsTitleBarContentOptions(new NGFHdsNavigationTitle(mainTitle, subTitle));
    const style = new NGFHdsTitleBarStyleOptions(originalBarStyle, scrollBarStyle);
    return new NGFHdsNavigationTitleBarOptions(content, style, avoidLayoutSafeArea, enableComponentSafeArea);
  }

  private static buildInternal(
    mainTitle: ResourceStr,
    subTitle: ResourceStr,
    backgroundColor: ResourceColor,
    materialLevel: hdsMaterial.MaterialLevel,
    avoidLayoutSafeArea: boolean,
    enableComponentSafeArea: boolean,
    originalMainTitleColor: ResourceColor,
    originalSubTitleColor: ResourceColor,
    scrollMainTitleColor: ResourceColor,
    scrollSubTitleColor: ResourceColor
  ): HdsNavigationTitleBarOptions {
    const originalTitleStyle = new NGFHdsNavigationTitleStyle(originalMainTitleColor, originalSubTitleColor);
    const scrollTitleStyle = new NGFHdsNavigationTitleStyle(scrollMainTitleColor, scrollSubTitleColor);
    const originalContentStyle = new NGFHdsTitleBarContentStyle(originalTitleStyle);
    const scrollContentStyle = new NGFHdsTitleBarContentStyle(scrollTitleStyle);
    const originalBackgroundStyle = new NGFHdsNavigationBackgroundStyle(backgroundColor, 18);
    const scrollBackgroundStyle = new NGFHdsNavigationBackgroundStyle(backgroundColor, 28);
    const originalBarStyle = new NGFHdsNavigationTitleBarStyle(originalBackgroundStyle, originalContentStyle);
    const scrollBarStyle = new NGFHdsNavigationTitleBarStyle(scrollBackgroundStyle, scrollContentStyle);
    const materialParams = NGFHdsEffectPresetFactory.buildSystemMaterialParams(hdsMaterial.MaterialType.IMMERSIVE, materialLevel);
    const content = new NGFHdsTitleBarContentOptions(new NGFHdsNavigationTitle(mainTitle, subTitle));
    const style = new NGFHdsTitleBarStyleOptions(originalBarStyle, scrollBarStyle, materialParams);
    return new NGFHdsNavigationTitleBarOptions(content, style, avoidLayoutSafeArea, enableComponentSafeArea);
  }
}
