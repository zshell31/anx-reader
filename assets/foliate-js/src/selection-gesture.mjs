/**
 * Owns the one click produced by a pointer gesture that began while a
 * SelectionSession was active. SelectionSessionMachine remains the sole
 * selection-lifetime authority; this object stores only pointer interaction
 * identity and never creates or advances a selection generation.
 */
export class SelectionGestureOwnership {
    #gesture = null

    beginPointer(owner, pointerId, generation, clientX, clientY) {
        // A new physical pointer interaction makes any click that failed to
        // arrive for the previous interaction stale.
        this.#gesture = generation == null ? null : {
            owner,
            pointerId,
            generation,
            clientX,
            clientY,
            pointerEnded: false,
        }
        return this.#gesture != null
    }

    endPointer(owner, pointerId, clientX, clientY) {
        if (!this.#matchesPointer(owner, pointerId)) return false
        // Browser click coordinates are derived from pointerup. Recording the
        // terminal point keeps ordinary tap slop tied to the same interaction.
        this.#gesture.clientX = clientX
        this.#gesture.clientY = clientY
        this.#gesture.pointerEnded = true
        return true
    }

    cancelPointer(owner, pointerId) {
        if (!this.#matchesPointer(owner, pointerId)) return false
        this.#gesture = null
        return true
    }

    consumeClick(owner, { pointerId, clientX, clientY } = {}) {
        const gesture = this.#gesture
        if (!gesture || gesture.owner !== owner || !gesture.pointerEnded) {
            return false
        }

        // PointerEvent.click carries pointerId on current WebViews. Retain the
        // coordinate identity fallback for WebViews exposing click as a plain
        // MouseEvent.
        if (pointerId != null && gesture.pointerId != null
            && pointerId !== gesture.pointerId) {
            return false
        }
        if (clientX !== gesture.clientX || clientY !== gesture.clientY) {
            return false
        }

        this.#gesture = null
        return true
    }

    invalidateOwner(owner) {
        if (this.#gesture?.owner !== owner) return false
        this.#gesture = null
        return true
    }

    #matchesPointer(owner, pointerId) {
        return this.#gesture?.owner === owner
            && this.#gesture.pointerId === pointerId
    }
}
