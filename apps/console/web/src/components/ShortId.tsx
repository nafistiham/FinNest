/**
 * A long opaque id, shown short until someone wants it whole.
 *
 * `sess_0514bed72579e966300e47282eaed931` is thirty-seven characters that an operator reads only
 * to compare against another one, and it was setting the width of the Who column for every row in
 * the table. Head and tail are what a comparison actually uses, so that is what is shown; a click
 * gives the whole thing, and a second click puts it back.
 */

import { useState } from 'react'

export function ShortId({ value, head = 9, tail = 4 }: { value: string; head?: number; tail?: number }) {
  const [open, setOpen] = useState(false)
  const short = value.length > head + tail + 1
  return (
    <span
      className={`shortid${short ? ' clickable' : ''}`}
      title={value}
      onClick={(event) => {
        if (!short) return
        event.stopPropagation()      // the row opens the drawer; this one only grows the id
        setOpen(!open)
      }}
    >
      {open || !short ? value : `${value.slice(0, head)}…${value.slice(-tail)}`}
    </span>
  )
}
