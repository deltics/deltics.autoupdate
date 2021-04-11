
{$i deltics.inc}

{$debuginfo OFF}

{$ifdef debug_DelticsAutoUpdate}
  {$undef InlineMethods}
  {$debuginfo ON}
{$endif}