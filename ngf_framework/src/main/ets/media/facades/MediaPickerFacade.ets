import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { IMediaPicker, NGFDocumentReadError, NGFTextDocument } from '../contracts/IMediaPicker';
import { logger } from '../../utils/Logger';
import { uiContextManager } from '../../platformOhos/UIContextManager';

const TAG: string = 'MediaPickerFacade';

export class MediaPickerFacade implements IMediaPicker {
  /**
   * 调起系统安全的图片选择器 (PhotoPicker)
   * 鸿蒙特性：不需要应用显式申请相册读权限，系统 Picker 选取后会直接返回临时授权的 URI
   */
  async pickImages(maxSelectNumber: number = 1): Promise<Array<string>> {
    const context = uiContextManager.getFullAbilityContext();
    if (!context) {
      logger.error(TAG, '缺少 UIAbilityContext，无法拉起图片选择器');
      return [];
    }

    try {
      const photoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      // 限定仅选择图片
      photoSelectOptions.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      photoSelectOptions.maxSelectNumber = maxSelectNumber;

      const photoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const photoSelectResult = await photoViewPicker.select(photoSelectOptions);

      const uris = photoSelectResult.photoUris;
      logger.info(TAG, '成功拾取 ' + String(uris.length) + ' 张图片');
      return uris;
    } catch (e) {
      logger.error(TAG, '图片拾取失败: ' + e);
      return [];
    }
  }

  /**
   * 调起系统安全的视频选择器
   */
  async pickVideos(maxSelectNumber: number = 1): Promise<Array<string>> {
    const context = uiContextManager.getFullAbilityContext();
    if (!context) {
      logger.error(TAG, '缺少 UIAbilityContext');
      return [];
    }

    try {
      const photoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      photoSelectOptions.MIMEType = photoAccessHelper.PhotoViewMIMETypes.VIDEO_TYPE;
      photoSelectOptions.maxSelectNumber = maxSelectNumber;

      const photoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const photoSelectResult = await photoViewPicker.select(photoSelectOptions);

      return photoSelectResult.photoUris;
    } catch (e) {
      logger.error(TAG, '视频拾取失败: ' + e);
      return [];
    }
  }
  /**
   * 调起系统安全的文件选择器
   */
  async pickDocuments(): Promise<Array<string>> {
    const context = uiContextManager.getFullAbilityContext();
    if (!context) {
      logger.error(TAG, '缺少 UIAbilityContext');
      return [];
    }

    try {
      // 鸿蒙 4.0 以后推荐使用 @ohos.file.picker
      const documentSelectOptions = new picker.DocumentSelectOptions();
      documentSelectOptions.maxSelectNumber = 1;

      const documentViewPicker = new picker.DocumentViewPicker();
      const documentSelectResult = await documentViewPicker.select(documentSelectOptions);

      logger.info(TAG, '成功拾取 ' + String(documentSelectResult.length) + ' 个文件');
      return documentSelectResult;
    } catch (e) {
      logger.error(TAG, '文件拾取失败: ' + e);
      return [];
    }
  }

  /** 单次可读取的文本文档大小上限，防止误选大文件时一次性分配过大内存。 */
  private static readonly MAX_TEXT_DOCUMENT_BYTES: number = 8 * 1024 * 1024;

  async pickDocumentText(): Promise<NGFTextDocument | null> {
    const uris = await this.pickDocuments();
    if (uris.length === 0) {
      // 用户取消或未选择文件时保持“取消”语义，与读取失败区分。
      return null;
    }

    const selectedUri = uris[0];
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(selectedUri, fileIo.OpenMode.READ_ONLY);
      // Picker 返回的是 file:// URI，不是应用沙箱路径；readTextSync 仅接受沙箱路径，
      // 直接传 file.path 在真机上必然失败，因此统一通过 fd 读取（与 FileUtils 相同模式）。
      const stat: fileIo.Stat = fileIo.statSync(file.fd);
      const size: number = stat.size;
      if (size <= 0) {
        throw new Error('selected document is empty');
      }
      if (size > MediaPickerFacade.MAX_TEXT_DOCUMENT_BYTES) {
        throw new Error('selected document is too large');
      }
      const buffer: ArrayBuffer = new ArrayBuffer(size);
      const readLength: number = fileIo.readSync(file.fd, buffer);
      if (readLength <= 0) {
        throw new Error('selected document could not be read');
      }
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      let content: string = decoder.decodeToString(new Uint8Array(buffer, 0, readLength));
      if (content.length > 0 && content.charCodeAt(0) === 0xFEFF) {
        content = content.substring(1);
      }
      if (content.trim().length <= 0) {
        throw new Error('selected document has no readable text');
      }
      return new NGFTextDocument(this.documentNameFromUri(selectedUri), content);
    } catch (e) {
      const detail: string = e instanceof Error ? e.message : String(e);
      logger.error(TAG, '文件文本读取失败: ' + detail);
      throw new NGFDocumentReadError(detail);
    } finally {
      if (file !== null) {
        try {
          fileIo.closeSync(file);
        } catch {
          // 释放句柄失败不影响已读取结果
        }
      }
    }
  }

  private documentNameFromUri(uri: string): string {
    const lastSlashIndex: number = uri.lastIndexOf('/');
    if (lastSlashIndex < 0 || lastSlashIndex + 1 >= uri.length) {
      return 'document';
    }
    let rawName: string = uri.substring(lastSlashIndex + 1);
    const queryIndex: number = rawName.indexOf('?');
    if (queryIndex > 0) {
      rawName = rawName.substring(0, queryIndex);
    }
    if (rawName.length <= 0) {
      return 'document';
    }
    try {
      return decodeURIComponent(rawName);
    } catch {
      // 文件名包含非法转义序列时保留原始形式
      return rawName;
    }
  }
}

export const ngfMediaPickerFacade: IMediaPicker = new MediaPickerFacade();
