// User-facing installs are complete model bundles. Low-level installModel remains
// available to integrity tests and import tools that explicitly name one asset set.
export function modelBundle(catalog, id) {
  const selected = catalog.find(model => model.id === id);
  if (!selected) throw new Error('Unknown curated model.');
  const base = selected.variantOf ? catalog.find(model => model.id === selected.variantOf) : selected;
  return [base, ...catalog.filter(model => model.variantOf === base.id)];
}

export async function installBundle(engine, catalog, id) {
  for (const model of modelBundle(catalog, id)) {
    if (!(await engine.installed(model))) await engine.installModel(model.id);
  }
}

export async function removeBundle(engine, catalog, id) {
  for (const model of modelBundle(catalog, id)) await engine.removeModel(model.id);
}

export function describeBundles(models) {
  return models.map(model => {
    if (model.variantOf) return model;
    const companion = models.find(item => item.variantOf === model.id);
    return { ...model, cpuInstalled: model.installed, gpuInstalled: companion?.installed ?? false,
      installed: model.installed || !!companion?.installed,
      bundleComplete: model.installed && (!companion || companion.installed),
      bundleSizeMB: model.sizeMB + (companion?.sizeMB ?? 0) };
  });
}
