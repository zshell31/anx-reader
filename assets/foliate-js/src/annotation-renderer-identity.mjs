export const rendererAnnotationKey = annotation =>
  annotation.renderKey ?? annotation.value

export const annotationForRenderKey = (annotationsById, renderKey) =>
  annotationsById.get(renderKey)
