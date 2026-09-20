export const coverDimensions = (width, height) => {
    if (!(width > 0 && height > 0 && Number.isFinite(width) && Number.isFinite(height)))
        throw new Error('Invalid cover dimensions')
    const scale = Math.min(1, 1000 / Math.max(width, height))
    return { width: Math.max(1, Math.floor(width * scale)),
        height: Math.max(1, Math.floor(height * scale)), scale }
}

const jpeg = canvas => new Promise((resolve, reject) => {
    canvas.toBlob(blob => blob ? resolve(blob) : reject(new Error('Cover encoding failed')),
        'image/jpeg', 0.82)
})

export const renderPdfCover = async page => {
    const natural = page.getViewport({ scale: 1 })
    const size = coverDimensions(natural.width, natural.height)
    const viewport = page.getViewport({ scale: size.scale })
    const canvas = document.createElement('canvas')
    canvas.width = size.width
    canvas.height = size.height
    await page.render({ canvasContext: canvas.getContext('2d'), viewport,
        background: 'rgb(255,255,255)' }).promise
    return jpeg(canvas)
}

export const compactCover = async blob => {
    if (!blob || blob.size <= 256 * 1024) return blob
    const bitmap = await createImageBitmap(blob)
    try {
        const size = coverDimensions(bitmap.width, bitmap.height)
        const canvas = document.createElement('canvas')
        canvas.width = size.width
        canvas.height = size.height
        const context = canvas.getContext('2d')
        context.fillStyle = '#ffffff'
        context.fillRect(0, 0, canvas.width, canvas.height)
        context.drawImage(bitmap, 0, 0, canvas.width, canvas.height)
        return await jpeg(canvas)
    } finally {
        bitmap.close()
    }
}
