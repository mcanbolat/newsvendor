# =====================================================================
#  FSA simulation: analysis of the "paper-format" CSV exported from
#  fsa/admin.html (same columns as Results/datasetforpaper.csv, plus
#  IncidentGroup). Reproduces Tables 2-4 of the paper, then adds the
#  2x2 and repeated-measures versions the web data now allow.
# =====================================================================
library(dplyr)

fsadata <- read.csv(file.choose())          # e.g. fsa_FSA101_paper_format.csv
# The original Excel dataset has no IncidentGroup column: everyone had the incident
if (!"IncidentGroup" %in% names(fsadata)) fsadata$IncidentGroup <- "Yes"
fsadata <- fsadata %>%
  arrange(ID, Period) %>%
  group_by(ID) %>%
  mutate(NCDiffL1 = lag(Need - Contribution)) %>%   # NCDiff_(i-1) in Table 4
  ungroup() %>%
  mutate(Information   = factor(Information, levels = c("No", "Yes")),
         Incident      = factor(Incident,    levels = c("No", "Yes")),
         IncidentGroup = factor(IncidentGroup, levels = c("No", "Yes")),
         ID            = factor(ID))

# ---- Table 2: summary statistics (as in the paper) -------------------
fsadata %>%
  group_by(IncidentGroup, Information, Incident) %>%
  summarise(participants = n_distinct(ID), n = n(),
            mean = mean(Contribution), sd = sd(Contribution), .groups = "drop")

# ---- Table 3: two-way ANOVA (as in the paper) ------------------------
# Uses only the incident groups, i.e. the design reported in the paper.
paper <- filter(fsadata, IncidentGroup == "Yes")
summary(aov(Contribution ~ Incident * Information, data = paper))

# ---- Table 4: regression with last year's contribution error --------
summary(lm(Contribution ~ NCDiffL1 + Incident * Information, data = paper))

# ---- Repeated measures: each student contributes 15 observations -----
# A random intercept per student avoids treating the 15 decisions as
# independent (what a reviewer may ask for).
if (requireNamespace("lmerTest", quietly = TRUE)) {
  library(lmerTest)
  summary(lmer(Contribution ~ Incident * Information + (1 | ID), data = paper))
}

# ---- Full 2x2: incident vs no-incident groups (difference-in-differences)
# Post = years after the incident year, for EVERY group, so the no-incident
# groups give the baseline drift over time.
if (nlevels(droplevels(fsadata$IncidentGroup)) == 2) {
  incident_year <- min(fsadata$Period[fsadata$Incident == "Yes"]) - 1
  fsadata$Post  <- factor(ifelse(fsadata$Period > incident_year, "Yes", "No"))
  if (requireNamespace("lmerTest", quietly = TRUE)) {
    summary(lmer(Contribution ~ Information * IncidentGroup * Post + (1 | ID), data = fsadata))
  } else {
    summary(aov(Contribution ~ Information * IncidentGroup * Post + Error(ID / Post), data = fsadata))
  }
}

# ---- Figure 6: what Astute students did with leftover funds ----------
fsadata %>%
  filter(!is.na(PCH)) %>%
  summarise(forms = n(), PCH = mean(PCH), HW = mean(HW), SC = mean(SC), Forfeit = mean(Forfeit))
