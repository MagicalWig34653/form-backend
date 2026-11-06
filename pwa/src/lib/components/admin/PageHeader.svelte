<script lang="ts">
  import type { Snippet } from 'svelte';
  import { cn } from '$lib/utils';
  import Breadcrumb, { type Crumb } from './Breadcrumb.svelte';

  interface Props {
    title: string;
    description?: string;
    breadcrumbs?: Crumb[];
    /** Status chips next to the title. */
    badges?: Snippet;
    actions?: Snippet;
    /** Soft accent wash behind the header (overview and form pages). */
    hero?: boolean;
    /** Id of the heading; App.svelte moves focus to #page-title after navigation. */
    id?: string;
    class?: string;
  }
  let {
    title,
    description,
    breadcrumbs = [],
    badges,
    actions,
    hero = false,
    id = 'page-title',
    class: className,
  }: Props = $props();
</script>

<header
  class={cn(
    'relative flex flex-col gap-1',
    hero && 'hero-wash -mx-4 -mt-8 px-4 pt-8 pb-2 md:-mx-8 md:px-8',
    className,
  )}
>
  {#if breadcrumbs.length > 0}<Breadcrumb items={breadcrumbs} class="mb-1" />{/if}
  <div class="flex flex-wrap items-start justify-between gap-x-4 gap-y-3">
    <div class="min-w-0 flex-1 basis-64">
      <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
        <h1 {id} tabindex="-1" class="min-w-0 break-words outline-none">{title}</h1>
        {#if badges}<div class="flex flex-wrap items-center gap-2">{@render badges()}</div>{/if}
      </div>
      {#if description}<p
          class="text-muted-foreground mt-1 max-w-3xl text-[length:var(--fs-body)] leading-[22px]"
        >
          {description}
        </p>{/if}
    </div>
    {#if actions}<div class="flex flex-wrap items-center gap-2">{@render actions()}</div>{/if}
  </div>
</header>
