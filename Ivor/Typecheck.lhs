> {-# OPTIONS_GHC -fglasgow-exts #-}

> module Ivor.Typecheck(typecheck, tcClaim,
>                       check, checkAndBind, checkAndBindWith, checkAndBindPair,
>                       convert,
>                       checkConv, checkConvEnv, pToV, pToV2,
>                       verify, Gamma) where

> import Ivor.TTCore
> import Ivor.Gadgets
> import Ivor.Nobby
> import Ivor.Unify
> import Ivor.Constant
> import Ivor.Errors
> import Ivor.Evaluator
> import Ivor.Values
> import Ivor.Overloading

> import Control.Monad.State
> import Data.List
> import Debug.Trace

Conversion in the presence of staging is a bit more than simply syntactic
equality on values, since it is possible values contain quoted code which
code be run later. So we say {'x} =~ {'y] iff x =~ y. Otherwise it's
syntactic.

> convert :: Gamma Name -> Indexed Name -> Indexed Name -> Bool
> convert g x y = convertEnv [] g x y

> convertEnv env g x y
>     = (convNormaliseEnv env g x) == (convNormaliseEnv env g y)
>   -- conv (Stage (Quote x)) (Stage (Quote y)) = convertEnv env g x y
>   -- need to actually reduce inside quotes to do conversion check

 convert g x y = trace ((show (normalise g x)) ++ " & " ++ (show (normalise g y))) $ (normalise g x)==(normalise g y)

> checkConv :: Gamma Name -> Indexed Name -> Indexed Name -> IError -> IvorM ()
> checkConv g x y err = if convert g x y then return ()
>	                 else ifail err

> checkConvEnv :: Env Name -> Gamma Name -> Indexed Name -> Indexed Name ->
>                 IError -> IvorM ()
> checkConvEnv env g x y err = if convertEnv env g x y then return ()
>                              else ifail err


*****
SORT OUT TOP LEVEL TYPECHECKING FUNCTIONS
DEFINE THE INTERFACE CLEARLY

These are: check, checkAndBind, checkAndBindPair.

All should work by generating constraints and solving them, differing only
in when the constraints get solved.
so....
1. Generate constraints
2. Unify, checking for conversion and creating a substitution
3. Substitute into term and type
*****

Top level typechecking function - takes a context and a raw term,
returning a pair of a term and its type

> typecheck :: Gamma Name -> Raw -> IvorM (Indexed Name,Indexed Name)
> typecheck gamma term = do t <- check gamma [] term Nothing
>			    return t

> typecheckAndBind :: Gamma Name -> Raw ->
>                     IvorM (Indexed Name,Indexed Name, Env Name)
> typecheckAndBind gamma term = checkAndBind gamma [] term Nothing

Check a term, and return well typed terms with explicit names (i.e. no
de Bruijn indices)

> tcClaim :: Gamma Name -> Raw -> IvorM (Indexed Name,Indexed Name)
> tcClaim gamma term = do (Ind t, Ind v) <- check gamma [] term Nothing
>			    {-trace (show t) $-}
>                         return (Ind (makePs t), Ind (makePs v))

Check takes a global context, a local context, the term to check and
its expected type, if known, and returns a pair of a term and its
type.

> type CheckState =
>     (Level, -- Level number
>      Bool, -- Inferring types of names (if true)
>      Env Name, -- Extra bindings, if above is true
>      -- conversion constraints; remember the environment at the time we tried
>      -- also the context of where the constraint came from
>      [(Env Name, Indexed Name, Indexed Name, Maybe FileContext)],
>      -- Metavariables we've introduce to define later
>      [Name],
>      Maybe FileContext)

> type Level = Int

> data FileContext = FC FilePath Int
>   deriving (Show, Eq)

> errCtxt :: Maybe FileContext -> IError -> IError
> errCtxt (Just (FC f l)) err = IContext (f ++ ":" ++ show l ++ ":") err
> errCtxt _ err = err

> errCtxtCS :: CheckState -> IError -> IError
> errCtxtCS (_,_,_,_,_,fc) err = errCtxt fc err

Finishes up type checking by making a substitution from all the conversion
constraints and applying it to the term and type.

> doConversion :: Raw -> Gamma Name ->
>                 [(Env Name, Indexed Name, Indexed Name,Maybe FileContext)] ->
>                 Indexed Name -> Indexed Name ->
>                 IvorM (Indexed Name, Indexed Name)
> doConversion raw gam constraints (Ind tm) (Ind ty) =
>     -- trace ("Finishing checking " ++ show tm ++ " with " ++ show (length constraints) ++ " equations\n" ++ showeqn (map (\x -> (True,x)) constraints)) $
>           -- Unify twice; first time collect the substitutions, second
>           -- time do them. Because we don't know what order we can solve
>           -- constraints in and they might depend on each other...
>       do let cs = nub constraints
>          (subst, nms) <- mkSubst $ (map (\x -> (True,x)) cs) ++
>                                    (map (\x -> (False,x)) cs)
>          let tm' = papp subst tm
>          let ty' = papp subst ty
>          return (Ind tm',Ind ty')

Handy to pass through all the variables, for tracing purposes when debugging.

>    where mkSubst xs = mkSubst' (P,[]) xs xs
>          mkSubst' acc [] all = return acc
>          mkSubst' acc (q:xs) all
>             = do acc' <- mkSubstQ acc q all
>                  mkSubst' acc' xs all
>
>          eqn (ok, (env, x, y, fc)) = if ok then (x,y,fc) else (x,y,Nothing)
>          showeqn all = concat $ map ((++"\n").show.eqn) all

>          mkSubstQ (s',nms) (ok, (env,Ind x,Ind y,fc)) all
>             = do -- (s',nms) <- mkSubst xs
>                  let x' = papp s' x
>                  let y' = papp s' y
>                  let (Ind y'') = -- trace ("Unifying with " ++ show x' ++ " and " ++ show (papp s' y) ++ "[" ++ show (x,y) ++ "]") $
>                                 eval_nf gam (Ind (papp s' y))
>                  uns <- case unifyenvErr ok gam env (Ind y') (Ind x') of
>                           Right uns -> return uns
>                           Left err -> -- trace (showeqn all) $
>                             case unifyenvErr ok gam env (Ind y'') (Ind x') of
>                               Right uns -> return uns
>                               Left err -> ifail (errCtxt fc (ICantUnify (Ind y') (Ind x')))

                         Failure err -> fail $ err ++"\n" ++ show nms ++"\n" ++ show constraints -- $ -} ++ " Can't convert "++show x'++" and "++show y' ++ "\n" ++ show constraints ++ "\n" ++ show nms

>                  extend s' nms uns

>          extend phi nms [] = return (phi, nms)
>          extend phi nms ((n,tm):uns)
>             = extend ((scomp $! (delta n tm)) $! phi) ((n,tm):nms) uns

>          scomp :: Subst -> Subst -> Subst
>          scomp s2 s1 tn = papp s2 (s1 tn)

>          delta n ty n' | n == n' = ty
>                        | otherwise = P n'

> convertAllEnv :: Gamma Name ->
>                  [(Env Name, Indexed Name, Indexed Name,Maybe FileContext)] ->
>                  Env Name -> IvorM (Env Name)
> convertAllEnv gam constraints [] = return []
> convertAllEnv gam constraints ((n,B b t):xs)
>       = do (Ind t', _) <- doConversion RStar gam constraints (Ind t) (Ind Star)
>            xs' <- convertAllEnv gam constraints xs
>            return ((n,B b t'):xs')

> check :: Gamma Name -> Env Name -> Raw -> Maybe (Indexed Name) ->
>          IvorM (Indexed Name, Indexed Name)
> check gam env tm mty = do
>   ((tm', ty'), (_,_,_,convs,_,_)) <- lvlcheck 0 False 0 gam env tm mty
>   tm'' <- doConversion tm gam convs tm' ty'
>   return tm''

> checkAndBind :: Gamma Name -> Env Name -> Raw ->
>                 Maybe (Indexed Name) ->
>                 IvorM (Indexed Name, Indexed Name, Env Name)
> checkAndBind gam env tm mty = do
>    ((v,t), (next,inf,e,convs,_,_)) <- lvlcheck 0 True 0 gam env tm mty
>    e <- convertAllEnv gam convs e
>    (v'@(Ind vtm),t') <- doConversion tm gam convs v t -- (normalise gam t1')
>    return (v',t',e)


Check a pattern and an intermediate computation together

> checkAndBindWith :: Gamma Name -> Raw -> Raw -> Name ->
>                     IvorM (Indexed Name, Indexed Name, Indexed Name, Indexed Name, Env Name)
> checkAndBindWith gam tm1 tm2 root = do
>    ((v1,t1), (next, inf, e, bs,_,_)) <- lvlcheck 0 True 0 gam [] tm1 Nothing
>    -- rename all the 'inferred' things to another generated name,
>    -- so that they actually get properly checked on the rhs
>    let realNames = mkNames next
>    -- The environment will need the conversions applying, to fill in any implicit
>    -- variables in the pattern
>    e <- convertAllEnv gam bs e
>    e' <- renameB gam realNames (renameBinders e)
>    (v1, t1) <- doConversion tm1 gam bs v1 t1
>    (v1', t1') <- fixupGam gam realNames (v1, t1)
>    (v1''@(Ind vtm),t1'') <- doConversion tm1 gam bs v1' t1' -- (normalise gam t1')
>    -- Drop names out of e' that don't appear in v1'' as a result of the
>    -- unification.
>    let namesbound = getNames (Sc vtm)
>    let ein = orderEnv (filter (\ (n, ty) -> n `elem` namesbound) e')
>    ((v2,t2), (_, _, e'', bs',metas,_)) <- lvlcheck 0 inf next gam ein tm2 Nothing
>    (v2',t2') <- doConversion tm2 gam bs' v2 t2 -- (normalise gam t2)
>    let retEnv = reverse (ein ++ e'')
>    if (null metas)
>       then return (v1',t1',v2',t2',retEnv)
>       else fail "Can't have metavariables here"

>  where mkNames 0 = []
>        mkNames n
>           = ([],Ind (P (MN ("INFER",n-1))),
>                 Ind (P (MN ("T",n-1))), "renaming"):(mkNames (n-1))
>        renameBinders [] = []
>        renameBinders (((MN ("INFER",n)),b):bs)
>                         = ((MN ("T",n),b):(renameBinders bs))
>        renameBinders (b:bs) = b:renameBinders bs

Check two things together, with the same environment and variable inference,
and with the same expected type.
We need this for checking pattern clauses...
Return a list of the functions we need to define to complete the definition.

> checkAndBindPair :: Gamma Name -> Raw -> Raw ->
>                     IvorM (Indexed Name, Indexed Name,
>                        Indexed Name, Indexed Name, Env Name,
>                        [(Name, Indexed Name)])
> checkAndBindPair gam tm1 tm2 = do
>    ((v1,t1), (next, inf, e, bs,_,_)) <- lvlcheck 0 True 0 gam [] tm1 Nothing
>    -- rename all the 'inferred' things to another generated name,
>    -- so that they actually get properly checked on the rhs
>    let realNames = mkNames next
>    -- The environment will need the conversions applying, to fill in any implicit
>    -- variables in the pattern
>    e <- convertAllEnv gam bs e
>    e' <- renameB gam realNames (renameBinders e)
>    (v1, t1) <- doConversion tm1 gam bs v1 t1
>    (v1'@(Ind lhsret), t1') <- fixupGam gam realNames (v1, t1)
>    (v1''@(Ind vtm),t1'') <- doConversion tm1 gam bs v1' t1' -- (normalise gam t1')
>    -- Drop names out of e' that don't appear in v1'' as a result of the
>    -- unification.
>    let namesbound = getNames (Sc vtm)
>    let ein = orderEnv (filter (\ (n, ty) -> n `elem` namesbound) e')
>    ((v2,t2), (_, _, e'', bs',metas,_)) <- {- trace ("Checking " ++ show tm2 ++ " has type " ++ show t1') $ -} lvlcheck 0 inf next gam ein tm2 (Just t1')
>    (v2'@(Ind rhsret),t2') <- doConversion tm2 gam bs' v2 t2 -- (normalise gam t2)
>    let retEnv = reverse (ein ++ e'')
>    if (null metas)
>       then return (Ind (forced gam lhsret),t1',Ind (forced gam rhsret),t2',retEnv, [])
>       else do let (Ind v2tt) = v2'
>               let (v2'', newdefs) = updateMetas v2tt
>               return (Ind (forced gam lhsret),t1',Ind (forced gam v2''),t2',retEnv, map (\ (x,y) -> (x, (normalise gam (Ind y)))) newdefs)

               if (null newdefs) then
                  else trace (traceConstraints bs') $ return (v1',t1',Ind v2'',t2',e'', map (\ (x,y) -> (x, Ind y)) newdefs)

>  where mkNames 0 = []
>        mkNames n
>           = ([],Ind (P (MN ("INFER",n-1))),
>                 Ind (P (MN ("T",n-1))), IMessage "renaming"):(mkNames (n-1))
>        renameBinders [] = []
>        renameBinders (((MN ("INFER",n)),b):bs)
>                         = ((MN ("T",n),b):(renameBinders bs))
>        renameBinders (b:bs) = b:renameBinders bs

We need to order environments so that names used later are bound first.
*sigh*. This is turning into an almighty hack... I'm not convinced an
ordinary sort will do all the comparisons we need. Still, it's O(n^3) but
n is unlikely ever to be very big. Let's rethink this if it proves a
bottleneck.

> orderEnv [] = []
> orderEnv (x:xs) = insertEnv x (orderEnv xs)
> insertEnv x [] = [x]

Insert here if the name at x does not appear later in any type.

> insertEnv x (y:ys) = if (appearsIn x (y:ys))
>                         then y:(insertEnv x ys)
>                         else x:y:ys

if (all (\e -> envLT x e) (y:ys))
                            then y:(insertEnv x ys)
                            else x:y:ys

>    where
>       appearsIn (n,_) env = any (n_in n) env
>       n_in n (n2, B _ t) = n `elem` (getNames (Sc t))

     envLT (n1,B _ t1) (n2,B _ t2)
              | n2 `elem` (getNames (Sc t1)) = False
              | otherwise = True -- not (n1 `elem` (getNames (Sc t2)))


> traceConstraints [] = ""
> traceConstraints ((_,x,y,_):xs) = show (x,y) ++ "\n" ++ traceConstraints xs

> inferName n = (MN ("INFER", n))

> lvlcheck :: Level -> Bool -> Int ->
>             Gamma Name -> Env Name -> Raw ->
>             Maybe (Indexed Name) ->
>             IvorM ((Indexed Name, Indexed Name), CheckState)
> lvlcheck lvl infer next gamma env tm exp
>     = -- let tms = getTerms tm in
>           runStateT (tcfixupTop env lvl tm exp) (next, infer, [], [], [], Nothing)
>  where

Do the typechecking, then unify all the inferred terms.

>  tcfixupTop env lvl t exp = do
>     tm@(Ind tmval,tmty) <- tc env lvl t exp
>     (next, infer, bindings, errs ,mvs, fc) <- get
>     -- First, insert inferred values into the term
>     tm'@(_, tmty') <- fixup errs tm
>     -- Then check the resulting type matches the expected type.
>     if infer then (case exp of
>              Nothing -> return ()
>              Just expty -> checkConvSt env gamma tmty' expty )
>       else return ()
>     -- Then fill in any remained inferred values we got by knowing the
>     -- expected type
>     (next, infer, bindings, errs, mvs, fc) <- get
>     tm@(Ind tmval, tmty) <- fixup errs tm
>     -- bindings <- fixupB gamma errs bindings
>     put (next, infer, bindings, errs, mvs, fc)
>     -- return (Ind (forced gamma tmval), tmty)
>     return tm

>  tcfixup env lvl t exp = do
>     tm@(_,tmty) <- tc env lvl t exp
>     -- case exp of
>     --   Nothing -> return ()
>     --   Just expt -> checkConvSt env gamma expt tmty "Type error"
>     (next, infer, bindings, errs, mvs, fc) <- get
>     tm' <- fixup errs tm
>     bindings <- (fixupB gamma errs) $! bindings
>     put (next, infer, bindings, errs, mvs, fc)
>     return tm'

tc has state threaded through -- state is a tuple of the next name to
generate, the stage we're at, and a list of conversion errors (which
will later be unified).  Needs an explicit type to help out ghc's
typechecker...

>  tc :: Env Name -> Level -> Raw -> Maybe (Indexed Name) ->
>        StateT CheckState IvorM (Indexed Name, Indexed Name)
>  tc env lvl (Var n) exp = do
>        (rv, rt) <- mkTT (lookupi n env 0) (glookup n gamma)
>        case exp of
>           Nothing -> return (rv,rt)
>           Just expt -> do checkConvSt env gamma rt expt
>                           return (rv,rt)

>    where mkTT (Just (i, B _ t)) _ = return (Ind (P n), Ind t)
>          mkTT Nothing (Just ((Fun _ _),t)) = return (Ind (P n), t)
>          mkTT Nothing (Just ((Partial _ _),t)) = return (Ind (P n), t)
>          mkTT Nothing (Just ((PatternDef _ _ _ _),t)) = return (Ind (P n), t)
>          mkTT Nothing (Just (Unreducible,t)) = return (Ind (P n), t)
>          mkTT Nothing (Just (Undefined,t)) = return (Ind (P n), t)
>          mkTT Nothing (Just ((ElimRule _),t)) = return (Ind (Elim n), t)
>          mkTT Nothing (Just ((PrimOp _ _),t)) = return (Ind (P n), t)
>          mkTT Nothing (Just ((DCon tag i _),t)) = return (Ind (Con tag n i), t)
>          mkTT Nothing (Just ((TCon i _),t)) = return (Ind (TyCon n i), t)
>          mkTT Nothing Nothing = defaultResult

>          lookupi x [] _ = Nothing
>          lookupi x ((n,t):xs) i | x == n = Just (i,t)
>          lookupi x (_:xs) i = lookupi x xs (i+1)

>          defaultResult = do
>              (next, infer, bindings, errs, mvs, fc) <- get
>              case lookup n bindings of
>                Nothing ->
>                 if infer then case exp of
>                        Nothing -> lift $ ifail (errCtxt fc (INoSuchVar n))
>                        Just (Ind t) -> do put (next, infer, (n, B Pi t):bindings, errs, mvs, fc)
>                                           return (Ind (P n), Ind t)
>                          else lift $ ifail (errCtxt fc (INoSuchVar n))
>                Just (B Pi t) -> return (Ind (P n), Ind t)

>  tc env lvl (ROpts ns) Nothing = fail $ "Need a type for overloaded names"
>  tc env lvl (ROpts ns) (Just exp) = fail $ "Overloading not implemented (" ++ show ns ++ " : " ++ show exp ++ ")"
>  tc env lvl (RApp f a) exp = do
>     (Ind fv, Ind ft) <- tcfixup env lvl f Nothing
>     let fnfng = normaliseEnv env emptyGam (Ind ft)
>     let fnf = normaliseEnv env gamma (Ind ft)
>     (rv, rt) <-
>       case (fnfng,fnf) of
>        ((Ind (Bind _ (B Pi s) (Sc t))),_) -> do
>          (Ind av,Ind at) <- tcfixup env lvl a (Just (Ind s))
>          let sty = (normaliseEnv env gamma (Ind s))
>          let tt = (Bind (MN ("x",0)) (B (Let av) at) (Sc t))
>          let tmty = (normaliseEnv env emptyGam (Ind tt))
>          checkConvSt env gamma (Ind at) sty
>          return (Ind (App fv av), tmty)
>        (_, (Ind (Bind _ (B Pi s) (Sc t)))) -> do
>          (Ind av,Ind at) <- tcfixup env lvl a (Just (Ind s))
>          checkConvSt env gamma (Ind at) (Ind s)
>          let tt = (Bind (MN ("x",0)) (B (Let av) at) (Sc t))
>          let tt' = (normaliseEnv env gamma (Ind tt))
>          return (Ind (App fv av), (normaliseEnv env gamma (Ind tt)))
>        _ -> fail $ "Cannot apply a non function type " ++ show ft ++ " to " ++ show a
>     -- return (rv,rt)
>     case exp of
>        Nothing -> return (rv,rt)
>        Just expt -> -- trace ("Checking " ++ show (rv, rt, expt)) $
>                      do checkConvSt env gamma rt expt
>                         return (rv,rt)
>  tc env lvl (RConst x) _ = lift $ tcConst x
>  tc env lvl RStar _ = return (Ind Star, Ind Star)
>  tc env lvl RLinStar _ = return (Ind LinStar, Ind Star)
>  tc env lvl (RFileLoc f l t) exp =
>     do (next, infer, bindings, errs, mvs, fc) <- get
>        put (next, infer, bindings, errs, mvs, Just (FC f l))
>        tc env lvl t exp

Pattern bindings are a special case since they may bind several names,
and we don't convert names to de Bruijn indices

>  tc env lvl (RBind n (B (Pattern p) ty) sc) exp = do
>     (gb, env) <- checkpatt gamma env lvl n p ty
>     let scexp = case exp of
>          Nothing -> Nothing
>          (Just (Ind (Bind sn sb (Sc st)))) -> Just $
>             normaliseEnv ((sn,sb):env) gamma (Ind st)
>     (Ind scv, Ind sct) <- tcfixup ((n,gb):env) lvl sc scexp
>     discharge gamma n gb (Sc scv) (Sc sct)

>  tc env lvl (RBind n b sc) exp = do
>     gb <- checkbinder gamma env lvl n b
>     let scexp = case exp of
>          Nothing -> Nothing
>          (Just (Ind (Bind sn sb (Sc st)))) -> Just $
>             normaliseEnv ((sn,sb):env) gamma (Ind st)
>          _ -> fail (show exp)
>     (Ind scv, Ind sct) <- tcfixup ((n,gb):env) lvl sc Nothing -- scexp
>     --discharge gamma n gb (Sc scv) (Sc sct)
>     discharge gamma n gb (pToV n scv) (pToV n sct)
>  tc env lvl l@(RLabel t comp) _ = do
>     (Ind tv, Ind tt) <- tcfixup env lvl t Nothing
>     let ttnf = normaliseEnv env gamma (Ind tt)
>     case ttnf of
>       (Ind Star) -> do compv <- checkComp env lvl comp
>                        return (Ind (Label tv compv), Ind Star)
>       _ -> fail $ "Type of label " ++ show l ++ " must be *"
>  tc env lvl (RCall comp t) _ = do
>     compv <- checkComp env lvl comp
>     (Ind tv, Ind tt) <- tcfixup env lvl t Nothing
>     let ttnf = normaliseEnv env gamma (Ind tt)
>     case ttnf of
>       (Ind (Label t comp)) -> return (Ind (Call compv tv), Ind t)
>       _ -> fail $ "Type of call must be a label"
>  tc env lvl (RReturn t) (Just exp) = do
>     let expnf = normaliseEnv env gamma exp
>     case expnf of
>       (Ind (Label lt comp)) -> do
>          (Ind tv, Ind tt) <- tcfixup env lvl t (Just (Ind lt))
>          checkConvSt env gamma (Ind lt) (Ind tt)
>          return (Ind (Return tv), Ind (Label tt comp))
>       _ -> fail $ "return " ++ show t++ " should give a label, got " ++ show expnf
>  tc env lvl (RReturn t) Nothing = fail $ "Need to know the type to return for "++show t
>  tc env lvl (RStage s) exp = do
>          (Ind sv, Ind st) <- tcStage env lvl s exp
>          return (Ind sv, Ind st)
>  tc env lvl RInfer (Just (Ind exp)) = do
>                       (next, infer, bindings, errs, mvs, fc) <- get
>                       let bindings' = if infer
>                                        then (inferName next, B Pi exp):bindings
>                                        else bindings
>                       put (next+1, infer, bindings', errs, mvs, fc)
>                       return (Ind (P (inferName next)), Ind exp)
>  tc env lvl RInfer Nothing = lift $ tacfail "Can't infer a term for placeholder"

If we have a metavariable, we need to record the type of the expression which
will solve it. It needs to take the environment as arguments, and return
the expected type.

>  tc env lvl (RMeta n) (Just (Ind exp))
>     = do (next, infer, bindings, errs, mvs, fc) <- get
>          put (next, infer, bindings, errs, n:mvs, fc)
>          -- Abstract it over the environment so that we have everything
>          -- in scope we need.
>          tm <- abstractOver (orderEnv env) n exp []
>          -- trace (show tm ++ " : " ++ show exp) $
>          return (tm,Ind exp)
> --              fail $ show (n, exp, bindings, env) ++ " -- Not implemented"
>    where abstractOver [] mv exp args =
>              return (Ind (appArgs (Meta mv exp) args))
>          abstractOver ((n,B _ t):ns) mv exp args =
>              abstractOver ns mv (Bind n (B Pi t) (pToV n exp)) ((P n):args)

          mkn (UN n) = MN (n,0)
          mkn (MN (n,x)) = MN (n,x+1)

>  tc env lvl (RMeta n) Nothing
>         -- just invent a name for it and see what inference gives us
>     = do (next, infer, bindings, errs, mvs, fc) <- get
>          put (next+1, infer, bindings, errs, mvs, fc)
>          -- let guessty = Bind (MN ("X", 0)) (B Pi (P (inferName next)))
>          --                 (Sc (P (inferName (next+1))))
>          let guessty = (P (inferName next))
>          tc env lvl (RMeta n) (Just (Ind guessty))

fail $ "Don't know the expected type of " ++ show n

>  tcStage env lvl (RQuote t) _ = do
>     (Ind tv, Ind tt) <- tc env (lvl+1) t Nothing
>     return (Ind (Stage (Quote tv)), Ind (Stage (Code tt)))
>  tcStage env lvl (RCode t) _ = do
>     (Ind tv, Ind tt) <- tc env lvl t Nothing
>     let ttnf = normaliseEnv env gamma (Ind tt)
>     case ttnf of
>       (Ind Star) -> return (Ind (Stage (Code tv)), Ind Star)
>       _ -> lift $ tacfail $ "Type of code " ++ show t ++ " must be *"
>  tcStage env lvl (REval t) _ = do
>     -- when (lvl/=0) $ fail $ "Can't eval at level " ++ show lvl
>     (Ind tv, Ind tt) <- tc env lvl t Nothing
>     let ttnf = normaliseEnv env gamma (Ind tt)
>     case ttnf of
>        (Ind (Stage (Code tcode))) ->
>            return (Ind (Stage (Eval tv tt)), Ind tcode)
>        _ -> lift $ tacfail $ "Can't eval a non-quoted term (type " ++ show ttnf ++ ")"
>  tcStage env lvl (REscape t) _ = do
>     -- when (lvl==0) $ fail $ "Can't escape at level " ++ show lvl
>     (Ind tv, Ind tt) <- tc env lvl t Nothing
>     let ttnf = normaliseEnv env gamma (Ind tt)
>     case ttnf of
>        (Ind (Stage (Code tcode))) ->
>            return (Ind (Stage (Escape tv tt)), Ind tcode)
>        _ -> lift $ tacfail "Can't escape a non-quoted term"

>  checkComp env lvl (RComp n ts) = do
>     tsc <- mapM (\ t -> tcfixup env lvl t Nothing) ts
>     return (Comp n (map ( \ (Ind v, Ind t) -> v) tsc))

Insert inferred values into the term

>  fixup e tm = fixupGam gamma e tm

>  tcConst :: (Constant c) => c -> IvorM (Indexed Name, Indexed Name)
>  tcConst c = return (Ind (Const c), Ind (constType c))

 tcConst Star = return (Ind (Const Star), Ind (Const Star)) --- *:* is a bit dodgy...

  checkbinder :: Monad m => Gamma Name -> Env Name -> Level ->
	          Name -> Binder Raw -> m (Binder (TT Name))

-- FIXME: Should convert here rather than assert it must be *

>  checkbinder gamma env lvl n (B Lambda t) = do
>     (Ind tv,Ind tt) <- tcfixup env lvl t (Just (Ind Star))
>     let ttnf = eval_nf_env env gamma (Ind tt)
>     let (Ind tvnf) = eval_nf_env env gamma (Ind tv)
>     case ttnf of
>       (Ind Star) -> return (B Lambda tvnf)
>       (Ind (P (MN ("INFER",_)))) -> return (B Lambda tvnf)
>       _ -> lift $ tacfail $ "The type of the binder " ++ show n ++ " must be *"
>  checkbinder gamma env lvl n (B Pi t) = do
>     (Ind tv,Ind tt) <- tcfixup env lvl t (Just (Ind Star))
>     let (Ind tvnf) = eval_nf_env env gamma (Ind tv)
>     let ttnf = -- trace ("PI: " ++ show (tv, tvnf, debugTT tv)) $
>                eval_nf_env env gamma (Ind tt)
>     -- checkConvSt env gamma ttnf (Ind AnyKind)
>     case ttnf of
>       (Ind Star) -> return (B Pi tv)
>       (Ind LinStar) -> return (B Pi tv)
>       (Ind (P (MN ("INFER",_)))) -> return (B Pi tv)
>       _ -> fail $ "The type of the binder " ++ show n ++ " must be *"
>     return (B Pi tvnf)


>  checkbinder gamma env lvl n (B (Let v) RInfer) = do
>     (Ind vv,Ind vt) <- tcfixup env lvl v Nothing
>     return (B (Let vv) vt)

>  checkbinder gamma env lvl n (B (Let v) t) = do
>     (Ind tv,Ind tt) <- tcfixup env lvl t (Just (Ind Star))
>     (Ind vv,Ind vt) <- tcfixup env lvl v (Just (Ind tv))
>     let ttnf = normaliseEnv env gamma (Ind tt)
>     lift $ checkConvEnv env gamma (Ind vt) (Ind tv) (INotConvertible (Ind vt) (Ind tv))
>     case ttnf of
>       (Ind Star) -> return (B (Let vv) tv)
>       _ -> lift $ tacfail $ "The type of the binder " ++ show n ++ " must be *"
>    where dbg (Ind t) = debugTT t

>  checkbinder gamma env lvl n (B Hole t) = do
>     (Ind tv,Ind tt) <- tcfixup env lvl t Nothing
>     let ttnf = normaliseEnv env gamma (Ind tt)
>     case ttnf of
>       (Ind Star) -> return (B Hole tv)
>       _ -> lift $ tacfail $ "The type of the binder " ++ show n ++ " must be *"
>  checkbinder gamma env lvl n (B (Guess v) t) = do
>     (Ind tv,Ind tt) <- tcfixup env lvl t Nothing
>     (Ind vv,Ind vt) <- tcfixup env lvl v Nothing
>     let ttnf = normaliseEnv env gamma (Ind tt)
>     lift $ checkConvEnv env gamma (Ind vt) (Ind tv) (INotConvertible (Ind vt) (Ind tv))
>     case ttnf of
>       (Ind Star) -> return (B (Guess vv) tv)
>       _ -> lift $ tacfail $ "The type of the binder " ++ show n ++ " must be *"

>  checkpatt gamma env lvl n RInfer t = do
>     (Ind tv,Ind tt) <- tcfixup env lvl t Nothing
>     return ((B MatchAny tv), env)
>  checkpatt gamma env lvl n pat t = do
>     (Ind tv,Ind tt) <- tcfixup env lvl t Nothing
>     (next, infer, bindings, err, mvs, fc) <- get
>     put (next, True, bindings, err, mvs, fc)
>     (Ind patv,Ind patt) <- tcfixup (bindings++env) lvl pat Nothing
>     (next, _ ,bindings, err, mvs, fc) <- get
>     put (next, infer, bindings, err, mvs, fc)
>     let ttnf = normaliseEnv env gamma (Ind tt)
>     --checkConvEnv env gamma (Ind patt) (Ind tv) $
>     --   show patt ++ " and " ++ show tv ++ " are not convertible"
>     case ttnf of
>       (Ind Star) -> return ((B (Pattern patv) tv), bindings++env)
>       _ -> lift $ tacfail $ "The type of the binder " ++ show n ++ " must be *"

Check a raw term representing a pattern. Return the pattern, and the
extended environment.

-- > checkPatt :: Monad m => Gamma Name -> Env Name -> Maybe (Pattern Name) ->
-- >              Raw -> Raw ->
-- >              m (Pattern Name, Env Name)
-- > checkPatt gam env acc (Var n) ty = trace (show n ++ ": "++ show env) $ do
-- >      (Ind tyc, _) <- check gam env ty (Just (Ind Star))
-- >      (pat, t) <- mkVarPatt (lookupi n env 0) (glookup n gam) (Ind tyc)
-- >      --checkConvEnv env gam (Ind tyc) (Ind t) $
-- >      --   show ty ++ " and " ++ show t ++ " are not convertible"
-- >      return (combinepats acc pat, (n, (B Pi tyc)):env)
-- >   where
-- >        mkVarPatt (Just (i, B _ t)) _ _ = return (PVar n, t)
-- >        mkVarPatt Nothing (Just ((DCon tag i), (Ind t))) _
-- >            = do tyname <- getTyName gam n
-- >                 return (PCon tag n tyname [], t)
-- >        mkVarPatt Nothing Nothing (Ind defty) = return (PVar n, defty)
-- >        lookupi x [] _ = Nothing
-- >        lookupi x ((n,t):xs) i | x == n = Just (i,t)
-- >        lookupi x (_:xs) i = lookupi x xs (i+1)

-- > checkPatt gam env acc (RApp f a) ty = do
-- >      (Ind tyc, _) <- trace (show ty) $ check gam env ty (Just (Ind Star))
-- >      let (RBind _ _ fscope) = ty
-- >      let (Bind nm (B _ nmt) _) = tyc
-- >      (fpat, fbindingsin) <- checkPatt gam env Nothing f ty
-- >      let fbindings = ((nm,(B Pi nmt)):fbindingsin)
-- >      (apat, abindings) <- checkPatt gam (fbindings++env)
-- >                                       (Just fpat) a fscope
-- >      return (combinepats (Just fpat) apat, fbindings++abindings)

--    where
--         mkEnv = map (\ (n,Ind t) -> (n, B Pi t))

-- > checkPatt gam env acc RInfer ty = return (combinepats acc PTerm, env)
-- > checkPatt gam env _ _ _ = fail "Invalid pattern"

> checkConvSt env g x y
>                 = do (next, infer, bindings, err, mvs, fc) <- get
>                      put (next, infer, bindings, (env,x,y,fc):err, mvs, fc)
>                      return ()

> fixupGam gamma [] tm = return tm
> fixupGam gamma ((env,x,y,_):xs) (Ind tm, Ind ty) = do
>      uns <- case unifyenv gamma env y x of
>                 Right x' -> return x'
>                 Left err -> return [] -- fail err -- $ "Can't convert "++show x++" and "++show y ++ " ("++show err++")"
>      let tm' = fixupNames gamma uns tm
>      let ty' = fixupNames gamma uns ty
>      fixupGam gamma xs (Ind tm', Ind ty')

> fixupNames gam [] tm = tm
> fixupNames gam ((x,ty):xs) tm = fixupNames gam xs $ substName x ty (Sc tm)

> fixupB gam xs bs = fixupB' gam xs bs []

> fixupB' gam xs [] acc = return acc
> fixupB' gam xs ((n, (B b t)):bs) acc =
>    -- if t is already fully explicit, don't bother
>   if (allExplicit (getNames (Sc t))) then fixupB' gam xs bs ((n,(B b t)):acc)
>       else do (Ind t', _) <- fixupGam gam xs (Ind t, Ind Star)
>               fixupB' gam xs bs ((n,(B b t')):acc)
>   where allExplicit [] = True
>         allExplicit ((MN ("INFER",_)):_) = False
>         allExplicit (_:xs) = allExplicit xs

> renameB gam xs [] = return []
> renameB gam xs ((n, (B b t)):bs) = do
>       bs' <- renameB gam xs bs
>       let t' = renameGam xs t
>       return ((n,(B b t')):bs')
>    where renameGam [] tm = tm
>          renameGam ((env,Ind (P x),Ind (P y),_):xs) tm =
>              let tm' = fixupNames gam [(x, P y)] tm in
>              renameGam xs tm'

> combinepats Nothing x = x
> combinepats (Just (PVar n)) x = error "can't apply things to a variable"
> combinepats (Just (PCon tag n ty args)) x = PCon tag n ty (args++[x])

> discharge :: Gamma Name -> Name -> Binder (TT Name) ->
>	       (Scope (TT Name)) -> (Scope (TT Name)) ->
>	       StateT CheckState IvorM (Indexed Name, Indexed Name)
> discharge gamma n (B Lambda t) scv sct = do
>    let lt = Bind n (B Pi t) sct
>    let lv = Bind n (B Lambda t) scv
>    return (Ind lv,Ind lt)
> discharge gamma n (B Pi t) scv (Sc sct) = do
>    case sct of
>      Star -> return ()
>      LinStar -> return ()
>      _ -> checkConvSt [] gamma (Ind Star) (Ind sct)
>    let lt = Star
>    let lv = Bind n (B Pi t) scv
>    return (Ind lv,Ind lt)
> discharge gamma n (B (Let v) t) scv sct = do
>    let lt = Bind n (B (Let v) t) sct
>    let lv = Bind n (B (Let v) t) scv
>    return (Ind lv,Ind lt)
> discharge gamma n (B Hole t) scv (Sc sct) = do
>    let lt = sct -- already checked sct and t are convertible
>    let lv = Bind n (B Hole t) scv
>    -- A hole can't appear in the type of its scope, however.
>    lift $ checkNotHoley 0 sct
>    return (Ind lv,Ind lt)
> discharge gamma n (B (Guess v) t) scv (Sc sct) = do
>    let lt = sct -- already checked sct and t are convertible
>    let lv = Bind n (B (Guess v) t) scv
>    -- A hole can't appear in the type of its scope, however.
>    lift $ checkNotHoley 0 sct
>    return (Ind lv,Ind lt)
> discharge gamma n (B (Pattern v) t) scv (Sc sct) = do
>    let lt = sct -- already checked sct and t are convertible
>    let lv = Bind n (B (Pattern v) t) scv
>    -- A hole can't appear in the type of its scope, however.
>    lift $ checkNotHoley 0 sct
>    return (Ind lv,Ind lt)
> discharge gamma n (B MatchAny t) scv (Sc sct) = do
>    let lt = sct
>    let lv = Bind n (B MatchAny t) scv
>    return (Ind lv,Ind lt)

> checkNotHoley :: Int -> TT n -> IvorM ()
> checkNotHoley i (V v) | v == i = fail "You can't put a hole where a hole don't belong."
> checkNotHoley i (App f a) = do checkNotHoley i f
>                                checkNotHoley i a
> checkNotHoley i (Bind _ _ (Sc s)) = checkNotHoley (i+1) s
> checkNotHoley i (Proj _ _ t) = checkNotHoley i t
> checkNotHoley _ _ = return ()

 checkR g t = (typecheck g t):: (Result (Indexed Name, Indexed Name))

If we're paranoid - recheck a supposedly well-typed term. Might want to
do this after finishing a proof.

> verify :: Gamma Name -> Indexed Name -> IvorM ()
> verify gam tm = do (_,_) <- typecheck gam (forget tm)
>                    return ()
