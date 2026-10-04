# The launcher with a `programs.logos` config applied.
cfg:
cfg.package.override {
  logosConfig = {
    inherit (cfg)
      wine
      theme
      renderer
      dpi
      graphicsDriver
      browser
      extraRegistry
      acceptEula
      blockAppUpdates
      updateCheck
      memoryHigh
      channel
      ;
  };
}
