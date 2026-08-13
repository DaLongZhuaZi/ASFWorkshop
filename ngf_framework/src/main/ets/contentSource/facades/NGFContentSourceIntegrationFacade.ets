import { common } from '@kit.AbilityKit';
import { NGFIntegrationFacadeBase } from '../../core/facades/NGFIntegrationFacadeBase';
import { NGFServiceRegistration } from '../../core/contracts/NGFServiceRegistration';
import { logger } from '../../utils/Logger';
import { ngfSourceLoaderFacade } from './SourceLoaderFacade';
import { ngfSourceRegistryFacade } from './SourceRegistryFacade';
import { ngfSourceRepositoryFacade } from './SourceRepositoryFacade';
import { ngfHttpClientFacade } from './HttpClientFacade';
import { ngfContentCacheFacade } from './ContentCacheFacade';
import { ngfContentPipelineFacade } from './ContentPipelineFacade';
import { ngfSourceHealthCheckerFacade } from './SourceHealthCheckerFacade';

const TAG: string = 'NGFContentSourceIntegrationFacade';

export class NGFContentSourceIntegrationFacade extends NGFIntegrationFacadeBase {
  protected readonly tag: string = 'NGFContentSourceIntegrationFacade';
  protected readonly appStorageKey: string = 'ngf_content_source_integrated';
  private runtimeInitialized: boolean = false;

  protected getServiceRegistrations(): Array<NGFServiceRegistration> {
    const registrations: Array<NGFServiceRegistration> = [];
    registrations.push(new NGFServiceRegistration('ngf.source.repository', 'SourceRepositoryFacade', ngfSourceRepositoryFacade as object));
    registrations.push(new NGFServiceRegistration('ngf.source.loader', 'SourceLoaderFacade', ngfSourceLoaderFacade as object));
    registrations.push(new NGFServiceRegistration('ngf.source.registry', 'SourceRegistryFacade', ngfSourceRegistryFacade as object));
    registrations.push(new NGFServiceRegistration('ngf.network.http_client', 'HttpClientFacade', ngfHttpClientFacade as object));
    registrations.push(new NGFServiceRegistration('ngf.source.content_cache', 'ContentCacheFacade', ngfContentCacheFacade as object));
    registrations.push(new NGFServiceRegistration('ngf.source.content_pipeline', 'ContentPipelineFacade', ngfContentPipelineFacade as object));
    registrations.push(new NGFServiceRegistration('ngf.source.health_checker', 'SourceHealthCheckerFacade', ngfSourceHealthCheckerFacade as object));
    return registrations;
  }

  protected onBootstrapped(): void {
    // The context bound during onCreate is not guaranteed to be valid for
    // file-backed services. Runtime initialization is performed by the
    // ability after WindowStage creation.
    logger.debug(TAG, '内容源模块已引导，等待有效 AbilityContext 后初始化运行时');
  }

  initializeRuntime(context: common.UIAbilityContext): void {
    if (this.runtimeInitialized) {
      return;
    }
    this.runtimeInitialized = true;
    ngfContentCacheFacade.initialize(context.filesDir);
    ngfSourceLoaderFacade.initialize(context.filesDir);
    ngfSourceRepositoryFacade.initialize(context.filesDir);
    logger.info(TAG, '内容源运行时初始化完成');
  }
}

export const ngfContentSourceIntegrationFacade = new NGFContentSourceIntegrationFacade();
