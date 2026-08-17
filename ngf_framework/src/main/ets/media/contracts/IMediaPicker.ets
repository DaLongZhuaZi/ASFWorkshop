export interface IMediaPicker {
  /**
   * 调起系统安全的图片选择器 (PhotoPicker)
   * @param maxSelectNumber 最大选择数量
   * @returns 选中图片的 URI 数组
   */
  pickImages(maxSelectNumber: number): Promise<Array<string>>;

  /**
   * 调起系统安全的视频选择器
   * @param maxSelectNumber 最大选择数量
   * @returns 选中视频的 URI 数组
   */
  pickVideos(maxSelectNumber: number): Promise<Array<string>>;
  /**
   * 调起系统安全的文件选择器 (DocumentPicker)
   * @returns 选中的文件 URI 数组
   */
  pickDocuments(): Promise<Array<string>>;

  /**
   * 调起系统安全的文件选择器并读取单个 UTF-8 文本文档，不向调用方暴露 URI。
   * @returns 用户取消选择时返回 null；已选中文件但读取失败时抛出 NGFDocumentReadError。
   */
  pickDocumentText(): Promise<NGFTextDocument | null>;
}

/** 用户已选中文件但内容读取失败时抛出，用于与“用户取消”（返回 null）区分。 */
export class NGFDocumentReadError extends Error {
  readonly detail: string;

  constructor(detail: string) {
    super(detail.length > 0 ? 'failed to read the selected document: ' + detail
      : 'failed to read the selected document');
    this.name = 'NGFDocumentReadError';
    this.detail = detail;
  }
}

export class NGFTextDocument {
  readonly name: string;
  readonly content: string;

  constructor(name: string, content: string) {
    this.name = name;
    this.content = content;
  }
}
