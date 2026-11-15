// The SDK must be linked as an application package product. Startup remains session-gated in Swift.
extern void E2EStudioSDKAutomaticStart(void);
__attribute__((constructor)) static void e2e_studio_initialize(void) {
    E2EStudioSDKAutomaticStart();
}
