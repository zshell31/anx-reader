export const rendererAnnotationKey = annotation =>
  annotation.renderKey ?? annotation.value

export const annotationForRenderKey = (annotationsById, renderKey) =>
  annotationsById.get(renderKey)

export const annotationForRemoval = (annotationsById, annotationId) =>
  annotationsById.get(annotationId)
